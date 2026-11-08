import SwiftUI
import UserNotifications
import EventKit
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct Reminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var date: Date
    var frequency: Frequency
    var interval: Int = 1
    var unit: IntervalUnit = .days
    var selectedWeekdays: [Int]?
    var weeklyEvery: Int?
    var monthlyEvery: Int?
    var monthlyOnLastDay: Bool?
    var monthlyDay: Int?
    var recurrenceAnchor: Date?
    var recurrenceWeekStart: Int?
    var recurrenceUntil: Date?
    var originalRecurrenceRule: String?
    var recurrenceReviewReason: String?
    var recurrenceImportVersion: Int?
    var weekdays: [Int] {
        let valid = Set((selectedWeekdays ?? []).filter { (1...7).contains($0) }).sorted()
        return valid.isEmpty ? [Calendar.current.component(.weekday, from: date)] : valid
    }
    func nextWeeklyOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return weekdays.compactMap { weekday -> Date? in
            var components = time
            components.weekday = weekday
            if isAllDay { components.hour = 0; components.minute = 0 }
            var cursor = reference
            for _ in 0...weeklyStep {
                guard let candidate = calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
                if isAllowedWeek(candidate, calendar: calendar) { return withinRecurrenceEnd(candidate) ? candidate : nil }
                cursor = candidate
            }
            return nil
        }.min()
    }
    func nextWeeklyAfterCompletion(at now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let reference = max(now, date)
        if isAllDay {
            // Completing a day's task moves to the next selected day, never later on the same day.
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))!
            return nextWeeklyOccurrence(after: tomorrow.addingTimeInterval(-1), calendar: calendar)
        }
        return nextWeeklyOccurrence(after: reference, calendar: calendar)
    }
    var enabled = true
    // Missing on older saved tasks: those remain silent reminders.
    var kind: Kind?
    enum Kind: String, Codable { case task, notification }
    var isNotification: Bool { kind == .notification }
    var shouldNotify: Bool { isNotification && enabled && !completed && frequency != .anytime && hasDueDate != false }
    var owner: Owner = .shared
    // Recovery copy of original imported text; editing uses a task-linked note.
    var notes: String = ""
    var linkedNoteID: UUID?
    var notesMigrationVersion: Int?
    var list: String = "Home"
    var listRulesVersion: Int?
    enum ListRole { case flexiblePersonal, flexibleHousehold, recurringPersonal, recurringHousehold }
    var listRole: ListRole? {
        switch list.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "personal recurring", "personal": return .recurringPersonal
        case "general recurring", "chores": return .recurringHousehold
        case "one-off personal tasks": return .flexiblePersonal
        case "errands", "one-off general tasks": return .flexibleHousehold
        default: return nil
        }
    }
    mutating func applyHouseholdListRules(personalOwner: Owner = .me) {
        guard !isNotification, listRulesVersion != 1, let role = listRole else { return }
        switch role {
        case .recurringPersonal:
            list = "Personal"
            if owner == .shared { owner = personalOwner }
        case .recurringHousehold:
            list = "Chores"
            owner = .shared
        case .flexiblePersonal:
            if owner == .shared { owner = personalOwner }
        case .flexibleHousehold:
            owner = .shared
        }
        if role == .flexiblePersonal || role == .flexibleHousehold {
            // Retain an explicitly configured LastTime month window; never invent a date for a one-off.
            if frequency != .flexible {
                frequency = .anytime
                hasDueDate = false
            }
        }
        listRulesVersion = 1
    }
    var completed = false
    var lastCompleted: Date?
    var dateBeforeCompletion: Date?
    var deferredUntil: Date?
    var deferredBeforeCompletion: Date?
    var history: [Date] = []
    var sourceID: String?
    var appleReminderExternalID: String?
    var appleReminderCalendarID: String?
    var deletedAt: Date?
    var allDay: Bool?
    var hasDueDate: Bool?
    var isUnscheduled: Bool { frequency == .anytime || (hasDueDate == false && frequency == .once) }
    var isFlexibleTask: Bool { !isNotification && (isUnscheduled || frequency == .flexible) }
    var syncsWithAppleReminders: Bool { !isNotification && !isFlexibleTask }
    func isAvailableFlexible(at now: Date = Date()) -> Bool {
        guard isFlexibleTask, deferredUntil == nil, !completed, deletedAt == nil else { return false }
        if frequency == .flexible {
            return dueMonth <= Calendar.current.dateInterval(of: .month, for: now)!.start
        }
        return true
    }
    var isAllDay: Bool {
        // Sage and Dan never schedule tasks at midnight; older imports may explicitly mark it timed.
        if !isNotification && Calendar.current.component(.hour, from: date) == 0 && Calendar.current.component(.minute, from: date) == 0 { return true }
        return allDay ?? false
    }
    static func shouldImport(completed: Bool, hasRecurrence: Bool) -> Bool { !completed || hasRecurrence }
    func isDueToday(at now: Date = Date()) -> Bool {
        guard !completed, !isNotification, deletedAt == nil else { return false }
        if let deferredUntil { return Calendar.current.isDate(deferredUntil, inSameDayAs: now) }
        guard !isFlexibleTask, hasDueDate != false else { return false }
        if [.daily, .weekly, .monthly, .custom].contains(frequency) {
            if let lastCompleted, Calendar.current.isDate(lastCompleted, inSameDayAs: now) { return false }
            let day = Calendar.current.startOfDay(for: now)
            guard Calendar.current.startOfDay(for: date) <= day,
                  let occurrence = nextScheduledOccurrence(after: day.addingTimeInterval(-1)) else { return false }
            return Calendar.current.isDate(occurrence, inSameDayAs: now)
        }
        return Calendar.current.isDate(date, inSameDayAs: now)
    }
    func isEligibleForTodayRandom(at now: Date = Date()) -> Bool {
        guard isDueToday(at: now) else { return false }
        if isAllDay || isFlexibleTask { return true }
        if let deferredUntil { return deferredUntil <= now }
        if [.daily, .weekly, .monthly, .custom].contains(frequency) {
            let start = Calendar.current.startOfDay(for: now)
            guard let occurrence = nextScheduledOccurrence(after: start.addingTimeInterval(-1)) else { return false }
            return occurrence <= now
        }
        return date <= now
    }

    enum Owner: String, Codable, CaseIterable {
        // Keep stored values stable for existing tasks and dashboard preferences.
        case me = "Me", husband = "Husband", shared = "Shared"
        var displayName: String {
            switch self { case .me: return "Sage"; case .husband: return "Dan"; case .shared: return "Shared" }
        }
    }
    var dueMonth: Date {
        let calendar = Calendar.current
        let anchor = lastCompleted ?? date
        let month = calendar.dateInterval(of: .month, for: anchor)!.start
        return lastCompleted == nil ? month : calendar.date(byAdding: .month, value: max(1, interval), to: month)!
    }
    var effectiveDate: Date { deferredUntil ?? (frequency == .flexible ? dueMonth : date) }
    static func orderedBefore(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    func isOverdue(at now: Date = Date()) -> Bool {
        guard !completed, deletedAt == nil else { return false }
        if let deferredUntil {
            return isAllDay || isFlexibleTask ? deferredUntil < Calendar.current.startOfDay(for: now) : deferredUntil < now
        }
        guard !isUnscheduled, hasDueDate != false else { return false }
        if frequency == .flexible { return Calendar.current.dateInterval(of: .month, for: dueMonth)!.end <= now }
        if [.daily, .weekly, .monthly, .custom].contains(frequency) && isDueToday(at: now) {
            if isAllDay { return false }
            let time = Calendar.current.dateComponents([.hour, .minute], from: date)
            let today = Calendar.current.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now)!
            return today < now
        }
        if isAllDay { return date < Calendar.current.startOfDay(for: now) }
        return date < now
    }
    enum Frequency: String, Codable, CaseIterable {
        case anytime = "Flexible (no date)", flexible = "Sometime in a month", once = "One-off", daily = "Daily", weekly = "Weekly", monthly = "Monthly", custom = "Custom interval"
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            let raw = try value.decode(String.self)
            guard let frequency = Self(rawValue: raw) else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown task frequency") }
            self = frequency
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            // An undated task uses the existing one-off representation plus hasDueDate=false.
            // Older installed builds can still decode the task while other devices update.
            try value.encode(self == .anytime ? Self.once.rawValue : rawValue)
        }
    }
    enum IntervalUnit: String, Codable, CaseIterable { case hours, days, weeks, months }
    var scheduleSummary: String {
        if (listRole == .recurringPersonal || listRole == .recurringHousehold), (frequency == .once || frequency == .anytime), recurrenceImportVersion != 1 {
            return "Recurring task · repeat schedule needs review"
        }
        if isUnscheduled { return "Flexible · no due date" }
        let timeSuffix = isAllDay ? "" : " at " + date.formatted(date: .omitted, time: .shortened)
        switch frequency {
        case .anytime: return "Flexible · no due date"
        case .flexible: return "Due sometime in \(dueMonth.formatted(.dateTime.month(.wide).year())) · every \(interval) month(s)"
        case .once: return hasDueDate == false ? "No due date" : date.formatted(date: .abbreviated, time: isAllDay ? .omitted : .shortened)
        case .daily: return "Every day\(timeSuffix)"
        case .weekly:
            let symbols = Calendar.current.weekdaySymbols
            return (weeklyStep == 1 ? "Every " : "Every \(weeklyStep) weeks on ") + weekdays.map { symbols[$0 - 1] }.joined(separator: ", ") + timeSuffix
        case .monthly:
            let cycle = monthlyStep == 1 ? "Monthly" : "Every \(monthlyStep) months"
            return cycle + (monthlyOnLastDay == true ? " on the last day" : " on day \(monthlyDay ?? Calendar.current.component(.day, from: recurrenceAnchor ?? date))") + timeSuffix
        case .custom: return "Every \(interval) \(unit.rawValue), starting \(date.formatted(date: .abbreviated, time: isAllDay ? .omitted : .shortened))"
        }
    }
}

struct HouseNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var archived: Bool?
    var deletedAt: Date?
    var sourceTaskID: UUID?
    var appleNotesSourceID: String?
    var appleNotesBodyIsCanonical: Bool?
    var appleNotesOriginalHTML: String?
    var appleNotesFolder: String?
    var appleNotesAttachmentCount: Int?
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title }
}

struct AppleNoteImportRecord: Identifiable, Sendable {
    var id: String
    var title: String
    var body: String
    var html: String
    var folder: String
    var attachments: Int
    var locked: Bool
    var readError: String?
    var canImport: Bool { !id.isEmpty && !locked && readError == nil }
}

struct AppleNoteImportResult {
    var imported = 0
    var alreadyImported = 0
    var unreadable = 0
    var withAttachments = 0
}

enum MealWeek {
    static func start(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let daysSinceSaturday = calendar.component(.weekday, from: day) % 7
        return calendar.date(byAdding: .day, value: -daysSinceSaturday, to: day)!
    }
    static func storageKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "househippo.dinnerDate.%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        #if os(iOS)
        [.banner, .list, .sound]
        #else
        []
        #endif
    }
}

@MainActor final class ReminderStore: ObservableObject {
    @Published var reminders: [Reminder] = []
    @Published var status: UNAuthorizationStatus = .notDetermined
    @Published var error: String?
    @Published var coverage: Date?
    private let events = EKEventStore()
    @Published var transferStatus: String?
    private let center = UNUserNotificationCenter.current()
    private let cloud = CloudStore.shared
    private var cloudObserver: AnyCancellable?
    init() {
        center.delegate = NotificationDelegate.shared
        #if os(macOS)
        // Remove alerts queued by earlier Mac builds without changing synced definitions.
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        #endif
        reloadTasks()
        cloudObserver = cloud.$revision.dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.reloadTasks() else { return }
                    await self.schedule()
                }
            }
    }
    @discardableResult private func reloadTasks() -> Bool {
        do {
            var loaded = try cloud.tasks()
            var corrections: [Reminder] = []
            for index in loaded.indices {
                let previous = loaded[index]
                loaded[index].applyHouseholdListRules()
                loaded[index].matchImportedRecurrence()
                try cloud.migrateTaskNote(&loaded[index])
                if loaded[index] != previous { corrections.append(loaded[index]) }
            }
            if !corrections.isEmpty { try cloud.saveAll(corrections) }
            loaded.sort(by: Reminder.orderedBefore)
            guard reminders != loaded else { return false }
            reminders = loaded
            return true
        } catch { self.error = "Your saved tasks could not be read. " + error.localizedDescription; return false }
    }
    func save(_ reminder: Reminder) async {
        do { try cloud.save(reminder); reloadTasks(); await schedule() }
        catch { self.error = "Could not save task: " + error.localizedDescription }
    }
    func complete(_ reminder: Reminder) async {
        var changed = reminder
        changed.markCompleted()
        await save(changed)
    }
    func moveToTomorrow(_ reminder: Reminder) async {
        guard var current = reminders.first(where: { $0.id == reminder.id }) else { return }
        current.moveToTomorrow()
        await save(current)
    }
    func undoCompletion(_ reminder: Reminder) async {
        guard var current = reminders.first(where: { $0.id == reminder.id }), current.wasCompletedToday() else { return }
        current.undoTodayCompletion()
        await save(current)
    }
    func reminderLists() async throws -> [EKCalendar] {
        guard try await events.requestFullAccessToReminders() else {
            throw NSError(domain: "HouseHippo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Reminders access in system settings to choose lists."])
        }
        return events.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func repairUndatedImports() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        var repaired: [Reminder] = []
        for var task in reminders where task.sourceID != nil && task.hasDueDate == nil && task.frequency == .once && !task.enabled && !task.completed && task.history.isEmpty {
            guard let sourceID = task.sourceID,
                  let original = events.calendarItem(withIdentifier: sourceID) as? EKReminder,
                  original.dueDateComponents == nil else { continue }
            task.hasDueDate = false
            task.frequency = .anytime
            repaired.append(task)
        }
        if !repaired.isEmpty { try cloud.saveAll(repaired); reloadTasks() }
    }
    func importReminders(listID: String? = nil, owner: Reminder.Owner = .shared) async -> Bool {
        do {
            guard try await events.requestFullAccessToReminders() else { error = "Allow Reminders access in System Settings to import your lists."; return false }
            try repairUndatedImports()
            let lists = events.calendars(for: .reminder)
            let selected = listID.map { id in lists.filter { $0.calendarIdentifier == id } }
            if selected?.isEmpty == true { error = "That Reminders list is no longer available. Choose another list."; return false }
            let fetched: [EKReminder] = await withCheckedContinuation { continuation in
                events.fetchReminders(matching: events.predicateForReminders(in: selected)) { continuation.resume(returning: $0 ?? []) }
            }
            var imported: [Reminder] = []
            for item in fetched where !reminders.contains(where: { $0.sourceID == item.calendarItemIdentifier }) {
                guard Reminder.shouldImport(completed: item.isCompleted, hasRecurrence: !(item.recurrenceRules ?? []).isEmpty) else { continue }
                var task = Reminder(title: item.title ?? "Untitled", message: "", date: item.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantPast, frequency: item.dueDateComponents == nil ? .anytime : .once)
                task.owner = owner
                task.hasDueDate = item.dueDateComponents != nil
                task.allDay = item.dueDateComponents?.hour == nil && item.dueDateComponents?.minute == nil
                task.notes = item.notes ?? ""
                task.list = item.calendar.title
                task.completed = item.isCompleted
                task.lastCompleted = item.completionDate
                task.sourceID = item.calendarItemIdentifier
                // Preserve recurrence text in notes until every EventKit rule can be represented faithfully.
                if let rules = item.recurrenceRules, !rules.isEmpty {
                    task.enabled = false
                    task.originalRecurrenceRule = rules.map { $0.description }.joined(separator: "; ")
                }
                if item.dueDateComponents == nil { task.enabled = false }
                task.applyHouseholdListRules(personalOwner: owner == .shared ? .me : owner)
                task.matchImportedRecurrence()
                try cloud.migrateTaskNote(&task)
                imported.append(task)
            }
            try cloud.saveAll(imported)
            reloadTasks()
            await schedule()
            transferStatus = "Imported \(imported.count) reminders from \(selected?.first?.title ?? "all lists"). Apple Reminders was left unchanged. Supported repeat schedules were matched automatically; only unmatched rules need review. Tasks do not send notifications."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func exportReminders() async {
        do {
            guard try await events.requestFullAccessToReminders() else { error = "Allow Reminders access to export."; return }
            guard let source = events.defaultCalendarForNewReminders()?.source else { error = "Add a writable Reminders account first."; return }
            var calendars: [String: EKCalendar] = [:]
            let tasks = reminders.filter { $0.syncsWithAppleReminders }
            for task in tasks {
                let name = "HouseHippo · " + task.list
                let calendar: EKCalendar
                if let existing = calendars[name] { calendar = existing }
                else {
                    calendar = EKCalendar(for: .reminder, eventStore: events)
                    calendar.title = name
                    calendar.source = source
                    try events.saveCalendar(calendar, commit: false)
                    calendars[name] = calendar
                }
                let item = EKReminder(eventStore: events)
                item.calendar = calendar
                item.title = task.title
                let noteText: String?
                if let id = task.linkedNoteID { noteText = try cloud.note(id: id)?.body }
                else { noteText = task.notesMigrationVersion != nil ? nil : task.notes }
                item.notes = noteText?.isEmpty == false ? noteText : nil
                item.isCompleted = task.completed
                if task.hasDueDate != false && !task.isUnscheduled {
                    let fields: Set<Calendar.Component> = task.isAllDay || task.frequency == .flexible ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
                    item.dueDateComponents = Calendar.current.dateComponents(fields, from: task.effectiveDate)
                }
                let end = task.recurrenceUntil.map { EKRecurrenceEnd(end: $0) }
                if task.recurrenceReviewReason == nil {
                    switch task.frequency {
                    case .weekly:
                        let days = task.weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
                        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: task.weeklyStep, daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
                        if task.weeklyStep == 1 || (task.recurrenceWeekStart ?? 2) == 2 { item.addRecurrenceRule(rule) }
                    case .monthly:
                        let day = task.monthlyOnLastDay == true ? -1 : (task.monthlyDay ?? Calendar.current.component(.day, from: task.recurrenceAnchor ?? task.date))
                        item.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .monthly, interval: task.monthlyStep, daysOfTheWeek: nil, daysOfTheMonth: [NSNumber(value: day)], monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end))
                    case .daily: item.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: end))
                    case .custom where task.unit == .days || task.unit == .weeks:
                        item.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: task.unit == .days ? .daily : .weekly, interval: max(1, task.interval), end: end))
                    default: break
                    }
                }
                try events.save(item, commit: false)
            }
            try events.commit()
            transferStatus = "Exported \(tasks.count) tasks to new HouseHippo lists. Flexible and custom schedules are included in notes; configure those repeats in Reminders. Exporting again creates another copy."
        } catch { events.reset(); self.error = error.localizedDescription }
    }
    func delete(_ reminder: Reminder) async {
        do { try cloud.delete(reminder); reloadTasks(); await schedule() }
        catch { self.error = "Could not delete task: " + error.localizedDescription }
    }
    func toggle(_ reminder: Reminder) async {
        var changed = reminder; changed.enabled.toggle(); await save(changed)
    }
    func refresh() async {
        reloadTasks()
        await cloud.checkAccount()
        #if os(iOS)
        status = await center.notificationSettings().authorizationStatus
        #endif
        await schedule()
    }
    func requestPermission() async {
        #if os(iOS)
        do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]); await refresh() }
        catch { self.error = error.localizedDescription }
        #endif
    }
    private func schedule() async {
        coverage = nil
        #if os(macOS)
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        #else
        guard status == .authorized || status == .provisional else { center.removeAllPendingNotificationRequests(); return }
        let active = reminders.filter { $0.shouldNotify && ($0.frequency != .once || $0.date > Date()) }
        // Reserve one request per native repeating reminder; share the remainder across custom schedules.
        let custom = active.filter { $0.usesRollingNotifications }
        let native = active.filter { !$0.usesRollingNotifications }
        let nativeCount = native.reduce(0) { $0 + ($1.frequency == .weekly ? $1.weekdays.count : 1) }
        guard nativeCount + custom.count <= 60 else {
            center.removeAllPendingNotificationRequests()
            error = "Notifications were cleared because more than 60 notifications are enabled. Pause some notifications to resume delivery; your tasks are still saved."; return
        }
        center.removeAllPendingNotificationRequests()
        let allocation = custom.isEmpty ? 0 : (60 - nativeCount) / custom.count
        do {
            for reminder in active {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.message
                content.sound = .default
                if reminder.usesRollingNotifications {
                    let dates: [Date]
                    if reminder.frequency == .flexible {
                        // A due-month nudge at 9am; overdue tasks remain visible until completed.
                        let start = max(Calendar.current.startOfDay(for: Date()), reminder.dueMonth)
                        let next = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: start)!
                        dates = [next > Date() ? next : Calendar.current.date(byAdding: .day, value: 1, to: next)!]
                    } else { dates = upcoming(reminder, count: allocation) }
                    for (index, date) in dates.enumerated() {
                        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                        try await center.add(UNNotificationRequest(identifier: "\(reminder.id)-\(index)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                    }
                    if let last = dates.last { coverage = min(coverage ?? last, last) }
                } else {
                    var fields: Set<Calendar.Component> = [.hour, .minute]
                    switch reminder.frequency {
                    case .once: fields.formUnion([.year, .month, .day])
                    case .weekly: fields.insert(.weekday)
                    case .monthly: fields.insert(.day)
                    default: break
                    }
                    var components = Calendar.current.dateComponents(fields, from: reminder.date)
                    if reminder.frequency == .monthly { components.day = reminder.monthlyDay ?? Calendar.current.component(.day, from: reminder.recurrenceAnchor ?? reminder.date) }
                    if reminder.frequency == .weekly {
                        for weekday in reminder.weekdays {
                            var selected = components
                            selected.weekday = weekday
                            try await center.add(UNNotificationRequest(identifier: "\(reminder.id)-weekday-\(weekday)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: selected, repeats: true)))
                        }
                    } else {
                        try await center.add(UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: reminder.frequency != .once)))
                    }
                }
            }
        } catch { self.error = "Could not schedule notifications: \(error.localizedDescription)" }
        #endif
    }
    private func upcoming(_ reminder: Reminder, count: Int) -> [Date] {
        var cursor = Date()
        var result: [Date] = []
        for _ in 0..<max(0, count) {
            guard let next = reminder.nextScheduledOccurrence(after: cursor) else { break }
            result.append(next); cursor = next
        }
        return result
    }
}

@main struct HouseHippoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HouseHippoDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(HouseHippoDelegate.self) private var delegate
    #endif
    @StateObject private var store = ReminderStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            HouseHippoHome().environmentObject(store)
                .task { AppleSyncService.shared.start(); await store.refresh() }
                .onChange(of: phase) { _, value in if value == .active { AppleSyncService.shared.request(); Task { await store.refresh() } } }
                .frame(minWidth: 340, minHeight: 500)
        }
    }
}

struct HouseHippoHome: View {
    @EnvironmentObject private var store: ReminderStore
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var selectedTab = 2
    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "pawprint.fill").font(.title2).foregroundStyle(.teal)
                        Text("HouseHippo").font(.title3.bold())
                    }.padding(18)
                    List(selection: Binding<Int?>(get: { selectedTab }, set: { if let value = $0 { selectedTab = value } })) {
                        Label("Dashboard", systemImage: "house").tag(2)
                        Label("Tasks", systemImage: "checklist").tag(1)
                        Label("Meals", systemImage: "fork.knife").tag(5)
                    }.listStyle(.sidebar)
                }.navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 250)
            } detail: {
                switch selectedTab {
                case 1: TaskList(mode: .tasks)
                case 2: HomeDashboard(navigate: { selectedTab = $0 })
                default: MealsView()
                }
            }.navigationSplitViewStyle(.balanced)
            #else
        TabView(selection: $selectedTab) {
            TaskList(mode: .notifications).tabItem { Label("Notifications", systemImage: "bell") }.tag(0)
            TaskList(mode: .tasks).tabItem { Label("Tasks", systemImage: "checklist") }.tag(1)
            HomeDashboard(navigate: { selectedTab = $0 }).tabItem { Label("Dashboard", systemImage: "house") }.tag(2)
            MealsView().tabItem { Label("Meals", systemImage: "fork.knife") }.tag(5)
        }
            #endif
        }
        .tint(.teal)
        .alert("HouseHippo", isPresented: Binding(get: { store.error != nil || store.transferStatus != nil }, set: { if !$0 { store.error = nil; store.transferStatus = nil } })) {
            Button("OK") { store.error = nil; store.transferStatus = nil }
        } message: { Text(store.error ?? store.transferStatus ?? "") }
    }
}

enum TaskMode { case dashboard, tasks, notifications }
struct TaskList: View {
    @EnvironmentObject private var store: ReminderStore
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var search = ""
    @State private var editing: Reminder?
    @State private var randomPick: Reminder?
    @State private var scope = "Active"
    @State private var confirmExport = false
    @State private var importing = false
    @State private var dashboardNow = Date()
    let mode: TaskMode
    private var filtered: [Reminder] {
        store.reminders.filter { task in
            let visible = mode != .dashboard || task.owner == .shared || task.owner.rawValue == person
            let relevant = mode == .notifications ? task.isNotification : !task.isNotification
            let matches = search.isEmpty || (task.title + " " + task.list).localizedCaseInsensitiveContains(search)
            return visible && relevant && matches && (mode != .dashboard || task.isDueToday(at: dashboardNow) || task.isAvailableFlexible(at: dashboardNow)) && (scope == "Completed" ? task.wasCompletedToday(at: dashboardNow) : !task.completed)
        }
    }
    var body: some View {
        let filtered = self.filtered
        return NavigationStack {
            List {
                if mode == .dashboard {
                    Section {
                        Text("A little more room for home.").font(.title2.bold())
                        Picker("Viewing as", selection: $person) { Text(Reminder.Owner.me.displayName).tag(Reminder.Owner.me.rawValue); Text(Reminder.Owner.husband.displayName).tag(Reminder.Owner.husband.rawValue) }
                        Text("Shared tasks and your own tasks appear here.").font(.caption).foregroundStyle(.secondary)
                        CloudStatusView()
                    }
                }
                if mode == .notifications {
                    Section("Delivery") {
                        #if os(iOS)
                        switch store.status {
                        case .notDetermined:
                            Button("Allow notifications") { Task { await store.requestPermission() } }
                        case .authorized:
                            Label("Notifications allowed", systemImage: "checkmark.circle")
                        case .provisional, .ephemeral:
                            Text("Notifications are allowed quietly or temporarily. Review delivery settings for banners and sounds.")
                            Link("Open notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                        case .denied:
                            Text("Notifications are disabled for HouseHippo on this iPhone.")
                            Link("Open notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                        @unknown default:
                            Text("Review HouseHippo notification permissions in Settings.")
                        }
                        #endif
                        if let coverage = store.coverage { Text("Open the app before \(coverage.formatted(date: .abbreviated, time: .shortened)) to refresh notification coverage.").font(.caption) }
                    }
                }
                if mode == .tasks {
                    Section {
                        Picker("Show", selection: $scope) { Text("Active").tag("Active"); Text("Completed today").tag("Completed") }.pickerStyle(.segmented)
                    }
                }
                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView(mode == .notifications ? "No notifications yet" : mode == .dashboard ? "Nothing due today" : scope == "Completed" ? "Nothing completed today" : "All clear", systemImage: mode == .notifications ? "bell" : "checkmark.circle", description: Text(mode == .notifications ? "Add a notification to schedule an alert. Tasks and reminders stay silent." : mode == .dashboard ? "Your other reminders are in Tasks." : scope == "Completed" ? "Tasks completed today appear here so you can undo them." : "Add a task or import your Apple Reminders."))
                        if mode != .notifications && (mode != .dashboard || !store.reminders.contains(where: { !$0.isNotification })) {
                            Button("Import Apple Reminders…", systemImage: "square.and.arrow.down") { importing = true }
                        }
                    }
                }
                if mode == .dashboard {
                    taskSection("Today's Tasks", tasks: filtered.filter { !$0.isFlexibleTask || $0.deferredUntil != nil }, random: true, todayRandom: true)
                    taskSection("Flexible Tasks", tasks: filtered.filter { $0.isFlexibleTask && $0.deferredUntil == nil }, random: true)
                } else { taskSection(mode == .notifications ? "Your notifications" : "Your reminders", tasks: filtered) }
            }
            .navigationTitle(mode == .dashboard ? "HouseHippo" : mode == .tasks ? "Tasks" : "Notifications")
            .searchable(text: $search, prompt: "Search tasks and lists")
            .onAppear { dashboardNow = Date() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
                dashboardNow = date
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button(mode == .notifications ? "Add notification" : "Add task", systemImage: "plus") {
                    var item = Reminder(title: "", message: "", date: Date().addingTimeInterval(3600), frequency: .once)
                    item.kind = mode == .notifications ? .notification : .task
                    editing = item
                } }
                if mode != .notifications {
                    ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Import Apple Reminders…") { importing = true }
                        Button("Export to Apple Reminders…") { confirmExport = true }
                    } label: { Label("Transfer", systemImage: "arrow.left.arrow.right") }
                    }
                }
            }
            .sheet(isPresented: $importing) { ReminderImportSheet().frame(minWidth: 340, minHeight: 350) }
            .sheet(item: $editing) { ReminderEditor(reminder: $0).frame(minWidth: 340, minHeight: 500) }
            .sheet(item: $randomPick) { RandomPickSheet(task: $0) }
            .confirmationDialog("Create new copies in Apple Reminders?", isPresented: $confirmExport, titleVisibility: .visible) {
                Button("Export tasks") { Task { await store.exportReminders() } }
            } message: { Text("Each export creates new lists and copies. Flexible and custom schedules are saved in notes and need to be configured in Reminders.") }
        }
    }
    @ViewBuilder private func taskSection(_ title: String, tasks: [Reminder], random: Bool = false, todayRandom: Bool = false) -> some View {
        if !tasks.isEmpty || random {
            Section(title) {
                if random {
                    Button("Pick a random task", systemImage: "dice") {
                        randomPick = tasks.filter { !todayRandom || $0.isEligibleForTodayRandom() }.randomElement()
                    }
                        .disabled(!tasks.contains { !todayRandom || $0.isEligibleForTodayRandom(at: dashboardNow) })
                        .accessibilityLabel("Pick a random task from " + title)
                    if tasks.isEmpty { Text("No tasks ready in this list.").foregroundStyle(.secondary) }
                }
                ForEach(tasks) { task in
                    HStack(spacing: 0) {
                        if task.isNotification {
                            Button { Task { await store.toggle(task) } } label: { Image(systemName: task.enabled ? "bell.fill" : "bell.slash").font(.title2).frame(width: 44).frame(maxHeight: .infinity).contentShape(Rectangle()) }.buttonStyle(.borderless)
                                .accessibilityLabel(task.enabled ? "Pause notification" : "Resume notification")
                        } else {
                            Button { Task {
                                if scope == "Completed" { await store.undoCompletion(task) }
                                else { await store.complete(task) }
                            } } label: { Image(systemName: scope == "Completed" ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44).frame(maxHeight: .infinity).contentShape(Rectangle()) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(scope == "Completed" ? "Undo completion" : "Mark done")
                        }
                        Button { editing = task } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.headline).foregroundStyle(.primary)
                                Text(task.summary).font(.caption).foregroundStyle(task.isOverdue() ? .red : .secondary)
                                Text("\(task.list) · \(task.owner.displayName)" + (task.isNotification && !task.enabled ? " · Paused" : "")).font(.caption).foregroundStyle(.secondary)
                                if let last = task.lastCompleted { Text("Last done \(last.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.leading, 8)
                            .padding(.trailing, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                    .contextMenu {
                        if task.isNotification {
                            Button(task.enabled ? "Pause notification" : "Resume notification") { Task { await store.toggle(task) } }
                        }
                        if task.canMoveToTomorrow && scope != "Completed" {
                            Button("Move to tomorrow", systemImage: "calendar.badge.clock") { Task { await store.moveToTomorrow(task) } }
                        }
                        Button("Delete", role: .destructive) { Task { await store.delete(task) } }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await store.delete(task) } } }
                }
            }
        }
    }
}

struct ReminderEditor: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State var reminder: Reminder
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section(reminder.isNotification ? "Notification" : "Task") {
                    TextField("Title", text: $reminder.title)
                    if reminder.isNotification {
                        TextField("Notification message", text: $reminder.message, axis: .vertical)
                    } else {
                        TextField("List", text: $reminder.list)
                        Picker("For", selection: $reminder.owner) { ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    }
                }
                Section("Schedule") {
                    if !reminder.isNotification {
                        Toggle("Flexible task", isOn: Binding(get: { reminder.isFlexibleTask }, set: { flexible in
                            reminder.frequency = flexible ? .anytime : .once
                            reminder.hasDueDate = !flexible
                            if !flexible { reminder.date = Date() }
                        }))
                    }
                    if !reminder.isFlexibleTask {
                    Picker("Repeat", selection: $reminder.frequency) { ForEach(Reminder.Frequency.allCases.filter { !reminder.isNotification || $0 != .anytime }, id: \.self) { Text($0.rawValue).tag($0) } }
                        .onChange(of: reminder.frequency) { old, new in
                            reminder.hasDueDate = new != .anytime
                            if old == .anytime && new != .anytime { reminder.date = Date() }
                        }
                    }
                    if reminder.isFlexibleTask {
                        FlexibleRepeatPicker(reminder: $reminder)
                    } else if reminder.frequency == .flexible {
                        DatePicker("First due month (day ignored)", selection: $reminder.date, displayedComponents: .date)
                        Stepper("Every \(reminder.interval) month(s)", value: $reminder.interval, in: 1...120)
                    } else {
                        if !reminder.isNotification {
                            Toggle("All day", isOn: Binding(get: { reminder.isAllDay }, set: { reminder.allDay = $0 }))
                        }
                        DatePicker(reminder.isAllDay ? "Due date" : "Date and time", selection: $reminder.date, displayedComponents: reminder.isAllDay ? [.date] : [.date, .hourAndMinute])
                            .onChange(of: reminder.date) { _, date in
                                reminder.hasDueDate = true
                                reminder.recurrenceAnchor = date
                            }
                        if reminder.frequency == .weekly {
                            WeeklyDaysPicker(reminder: $reminder)
                        }
                        if reminder.frequency == .monthly { MonthlyRepeatPicker(reminder: $reminder) }
                        if reminder.frequency == .custom {
                            Stepper("Every \(reminder.interval) \(reminder.unit.rawValue)", value: $reminder.interval, in: 1...365)
                            Picker("Unit", selection: $reminder.unit) { ForEach(Reminder.IntervalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        }
                    }
                    if reminder.isNotification { Toggle("Notification enabled", isOn: $reminder.enabled) }
                    Text(reminder.summary).font(.caption)
                    if reminder.frequency == .monthly && reminder.monthlyOnLastDay != true { Text("Months without the selected day are skipped.").font(.caption) }
                    if let reason = reminder.recurrenceReviewReason {
                        Text("Please review: " + reason).foregroundStyle(.orange)
                        Button("Confirm selected HouseHippo repeat schedule") {
                            reminder.recurrenceReviewReason = nil
                            reminder.recurrenceImportVersion = 1
                        }
                    }
                    if let raw = reminder.originalRecurrenceRule {
                        DisclosureGroup("Original Apple repeat rule") { Text(raw).font(.caption).textSelection(.enabled) }
                    }
                    if ![Reminder.Frequency.once, .anytime, .flexible].contains(reminder.frequency) {
                        Toggle("End repeat", isOn: Binding(get: { reminder.recurrenceUntil != nil }, set: { reminder.recurrenceUntil = $0 ? (reminder.recurrenceUntil ?? Date()) : nil }))
                        if reminder.recurrenceUntil != nil {
                            DatePicker("Ends", selection: Binding(get: { reminder.recurrenceUntil ?? Date() }, set: { reminder.recurrenceUntil = $0 }))
                        }
                    }
                }
                if !reminder.isNotification && !reminder.completed && store.reminders.contains(where: { $0.id == reminder.id }) {
                    Section { Button("Mark done", systemImage: "checkmark.circle") { Task { await store.complete(reminder); dismiss() } } }
                }
                TaskLinkedNoteSection(reminder: $reminder)
                if !reminder.history.isEmpty {
                    Section("Completion history") { ForEach(reminder.history.reversed(), id: \.self) { Text($0.formatted(date: .abbreviated, time: .shortened)) } }
                }
            }.formStyle(.grouped)
            .navigationTitle(reminder.isNotification ? "Notification details" : "Task details")
            .onAppear { if reminder.isUnscheduled { reminder.frequency = .anytime } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        reminder.title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        reminder.recurrenceAnchor = reminder.recurrenceAnchor ?? reminder.date
                        reminder.recurrenceImportVersion = 1
                        if reminder.frequency == .weekly {
                            reminder.selectedWeekdays = reminder.weekdays
                            let start = Calendar.current.startOfDay(for: max(Date(), reminder.date))
                            reminder.date = reminder.nextWeeklyOccurrence(after: start.addingTimeInterval(-1)) ?? reminder.date
                        }
                        Task { await store.save(reminder); dismiss() } }.disabled(saving || reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct MealsView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var dinners = Array(repeating: "", count: 7)
    @State private var week = MealWeek.start(containing: Date())
    private var currentDinners: [String] {
        (0..<7).map { day in
            let date = Calendar.current.date(byAdding: .day, value: day, to: week)!
            return (try? cloud.read(MealWeek.storageKey(for: date))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Previous week", systemImage: "chevron.left") { moveWeek(-1) }
                        Spacer()
                        Text("Week of \(week.formatted(date: .abbreviated, time: .omitted))")
                        Spacer()
                        Button("Next week", systemImage: "chevron.right") { moveWeek(1) }
                    }
                }
                Section("Dinner · drag a day onto another to swap") {
                    ForEach(0..<7, id: \.self) { day in
                        HStack {
                            Text(Calendar.current.date(byAdding: .day, value: day, to: week)!.formatted(.dateTime.weekday(.abbreviated))).frame(width: 45)
                            TextField("What's for dinner?", text: $dinners[day])
                        }
                        .draggable(String(day))
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, let from = Int(value), (0..<7).contains(from) else { return false }
                            dinners.swapAt(from, day); return true
                        }
                    }
                }
                Section("Grocery list") { GroceryView() }
            }.formStyle(.grouped).navigationTitle("Meals")
            .onAppear {
                do { try cloud.migrateMealDates(); dinners = currentDinners }
                catch { cloud.report(error) }
            }
            .onChange(of: dinners) { old, value in
                do {
                    let stored = currentDinners
                    for day in 0..<7 where old[day] != value[day] && stored[day] != value[day] {
                        let date = Calendar.current.date(byAdding: .day, value: day, to: week)!
                        try cloud.put(Data(value[day].utf8), key: MealWeek.storageKey(for: date))
                    }
                } catch { cloud.report(error) }
            }
            .onChange(of: cloud.revision) { _, _ in
                do { try cloud.migrateMealDates() } catch { cloud.report(error) }
                let incoming = currentDinners
                if dinners != incoming { dinners = incoming }
            }
        }
    }
    private func moveWeek(_ offset: Int) {
        week = Calendar.current.date(byAdding: .weekOfYear, value: offset, to: week)!
        dinners = currentDinners
    }
}
struct ReminderImportSheet: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [EKCalendar] = []
    @State private var selected = "all"
    @AppStorage("househippo.person") private var activePerson = Reminder.Owner.me.rawValue
    @State private var owner = Reminder.Owner.me
    @State private var loading = true
    @State private var importing = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Loading Apple Reminders lists…") }
                else if let issue { Text(issue).foregroundStyle(.red) }
                else if lists.isEmpty { Text("No Apple Reminders lists are available.") }
                else {
                    Picker("Import", selection: $selected) {
                        Text("All lists").tag("all")
                        ForEach(lists, id: \.calendarIdentifier) { list in
                            Text("\(list.title) · \(list.source.title)").tag(list.calendarIdentifier)
                        }
                    }
                    Picker("Tasks belong to", selection: $owner) {
                        ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("Only the selected list is copied when you choose one. Existing imports are skipped. Completed one-off tasks are skipped. Undated tasks remain flexible, without an invented deadline.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            .navigationTitle("Import Reminders")
            .task {
                owner = Reminder.Owner(rawValue: activePerson) ?? .me
                do { lists = try await store.reminderLists() }
                catch { issue = error.localizedDescription }
                loading = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importing ? "Importing…" : "Import") {
                        importing = true
                        Task {
                            if await store.importReminders(listID: selected == "all" ? nil : selected, owner: owner) { dismiss() }
                            else { issue = store.error; store.error = nil }
                            importing = false
                        }
                    }.disabled(loading || importing || lists.isEmpty || issue != nil)
                }
            }
            .interactiveDismissDisabled(importing)
        }
    }
}

struct WeeklyDaysPicker: View {
    @Binding var reminder: Reminder
    var body: some View {
        VStack(alignment: .leading) {
            Stepper("Every \(reminder.weeklyStep) week(s)", value: Binding(get: { reminder.weeklyStep }, set: { reminder.weeklyEvery = $0 }), in: 1...365)
            Text("Repeat on")
            ForEach(1...7, id: \.self) { day in
                Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { reminder.weekdays.contains(day) }, set: { selected in
                    var days = Set(reminder.weekdays)
                    if selected { days.insert(day) }
                    else if days.count > 1 { days.remove(day) }
                    reminder.selectedWeekdays = days.sorted()
                }))
            }
            Text("Choose one or more days. Completing this task advances to the next selected day.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MonthlyRepeatPicker: View {
    @Binding var reminder: Reminder
    var body: some View {
        VStack(alignment: .leading) {
            Stepper("Every \(reminder.monthlyStep) month(s)", value: Binding(get: { reminder.monthlyStep }, set: { reminder.monthlyEvery = $0 }), in: 1...365)
            Toggle("Last day of the month", isOn: Binding(get: { reminder.monthlyOnLastDay == true }, set: { reminder.monthlyOnLastDay = $0 }))
            if reminder.monthlyOnLastDay != true {
                Stepper("Day \(reminder.monthlyDay ?? Calendar.current.component(.day, from: reminder.date))", value: Binding(get: { reminder.monthlyDay ?? Calendar.current.component(.day, from: reminder.date) }, set: { reminder.monthlyDay = $0 }), in: 1...31)
            }
        }
    }
}

struct FlexibleRepeatPicker: View {
    @Binding var reminder: Reminder
    var body: some View {
        Picker("Repeat", selection: Binding(get: { reminder.frequency == .flexible }, set: { repeats in
            reminder.frequency = repeats ? .flexible : .anytime
            reminder.hasDueDate = repeats
            if repeats {
                if reminder.date < Date(timeIntervalSince1970: 0) { reminder.date = Date() }
                reminder.completed = false
            }
        })) {
            Text("Does not repeat").tag(false)
            Text("Every N months").tag(true)
        }
        if reminder.frequency == .flexible {
            Stepper("Once every \(reminder.interval) month(s)", value: $reminder.interval, in: 1...120)
            HStack {
                ForEach([1, 3, 6], id: \.self) { months in
                    Button(months == 1 ? "Monthly" : "Every \(months) months") { reminder.interval = months }
                }
            }.buttonStyle(.bordered)
            if reminder.lastCompleted == nil {
                DatePicker("First due month (day ignored)", selection: $reminder.date, displayedComponents: .date)
            }
            Text("Next due: \(reminder.dueMonth.formatted(.dateTime.month(.wide).year()))").font(.callout)
            Text("Do it once during the due month. After completion, the next due month is calculated from the month you actually did it. It stays out of Flexible Tasks until then.").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Do it whenever you can. Completing it finishes the task; it won't repeat.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
