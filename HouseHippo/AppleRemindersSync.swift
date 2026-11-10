import Foundation
import EventKit

struct AppleRemindersWriteFailure: LocalizedError {
    let operation: String
    let underlying: Error
    let movingLists: Bool

    var errorDescription: String? {
        let error = underlying as NSError
        if error.domain == "com.apple.reminderkit", error.code == -3002, movingLists {
            return "Apple Reminders refused to move this task between lists. Move it in Reminders, then sync again. The original reminder was kept."
        }
        return "Could not \(operation): \(error.localizedDescription) (\(error.domain), \(error.code)). This task will be retried; other tasks can still sync."
    }
}

@MainActor final class AppleRemindersAdapter {
    let events = EKEventStore()
    // Failed EventKit saves can leave dirty objects behind. Isolate writes from
    // the read snapshot and reset this store between individual operations.
    private let writes = EKEventStore()
    private func write<T>(_ operation: String, movingLists: Bool = false, body: (EKEventStore) throws -> T) throws -> T {
        writes.reset()
        do { return try body(writes) }
        catch {
            writes.reset()
            throw AppleRemindersWriteFailure(operation: operation, underlying: error, movingLists: movingLists)
        }
    }
    func authorize() async throws {
        guard try await events.requestFullAccessToReminders() else { throw Self.failure("Allow Reminders access in system settings") }
    }
    func calendars() -> [EKCalendar] { events.calendars(for: .reminder).filter(\.allowsContentModifications).sorted { $0.title < $1.title } }
    func snapshot(settings: AppleSyncSettings, known: [AppleSyncCheckpoint]) async throws -> [EKReminder] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw Self.failure("Reminders access is unavailable; sync is paused") }
        let selected = calendars().filter { settings.calendarIDs.contains($0.calendarIdentifier) }
        guard selected.count == settings.calendarIDs.count, !selected.isEmpty else { throw Self.failure("A selected Reminders list is unavailable; no deletions will be inferred") }
        let items: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            events.fetchReminders(matching: events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: selected)) {
                guard let result = $0 else { continuation.resume(throwing: Self.failure("Reminders returned an incomplete snapshot")); return }
                continuation.resume(returning: result)
            }
        }
        var result = Dictionary(items.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        // Each lookup is a synchronous round trip to the Reminders service. With a few hundred
        // known tasks that blocked the main thread for seconds on every sync, so run them off it.
        // Checkpoints and task records repeat the same identifiers; look each one up once.
        var seenSources = Set<String>(), seenExternals = Set<String>()
        let lookups = known.map { checkpoint in
            (source: seenSources.insert(checkpoint.sourceID).inserted ? checkpoint.sourceID : nil,
             external: checkpoint.externalID.flatMap { seenExternals.insert($0).inserted ? $0 : nil })
        }
        let store = events
        let found = await Task.detached(priority: .userInitiated) { () -> [EKReminder] in
            var found: [EKReminder] = []
            for lookup in lookups {
                if let source = lookup.source, let item = store.calendarItem(withIdentifier: source) as? EKReminder { found.append(item) }
                if let external = lookup.external {
                    for case let item as EKReminder in store.calendarItems(withExternalIdentifier: external) { found.append(item) }
                }
            }
            return found
        }.value
        for item in found { result[item.calendarItemIdentifier] = item }
        return Array(result.values)
    }
    nonisolated static func listName(_ source: String) -> String {
        switch source.lowercased() { case "personal recurring": return "Personal"; case "general recurring": return "Chores"; default: return source }
    }
    struct ListCandidate {
        let id: String
        let name: String
    }
    nonisolated static func destinationID(for task: Reminder, lists: [ListCandidate], settings: AppleSyncSettings) throws -> String {
        let selected = lists.filter { settings.calendarIDs.contains($0.id) }
        // Household assignment is not a request to move an existing Apple reminder.
        if let id = task.appleReminderCalendarID,
           selected.contains(where: { $0.id == id && listName($0.name) == task.list }) { return id }
        let sameName = selected.filter { listName($0.name) == task.list }
        if sameName.count == 1 { return sameName[0].id }
        let sameOwner = sameName.filter { settings.calendarOwners[$0.id] == task.owner.rawValue }
        if sameOwner.count == 1 { return sameOwner[0].id }
        // A linked task must never silently fall back to an unrelated list.
        if task.sourceID != nil || task.appleReminderCalendarID != nil || !sameName.isEmpty {
            throw Self.failure("Choose an unambiguous Reminders list matching ‘" + task.list + "’. This task's existing Apple list has not been changed.")
        }
        let owned = selected.filter { settings.calendarOwners[$0.id] == task.owner.rawValue }
        if owned.count == 1 { return owned[0].id }
        guard owned.contains(where: { $0.id == settings.defaultCalendarID }) else { throw Self.failure("Choose an accessible Reminders list for " + task.owner.displayName + "; tasks will not be sent to another person's list") }
        return settings.defaultCalendarID
    }
    func destination(for task: Reminder, settings: AppleSyncSettings) throws -> String {
        try Self.destinationID(for: task, lists: calendars().map { ListCandidate(id: $0.calendarIdentifier, name: $0.title) }, settings: settings)
    }
    func localValue(_ task: Reminder, settings: AppleSyncSettings) throws -> SyncedTaskValue {
        try Self.taskValue(task, calendarID: destination(for: task, settings: settings))
    }
    nonisolated static func taskValue(_ task: Reminder, calendarID: String) throws -> SyncedTaskValue {
        if task.frequency == .flexible { throw Self.failure("Flexible month windows do not have an exact Apple Reminders recurrence. Keep this schedule in HouseHippo or choose a calendar repeat before syncing it.") }
        if let reason = task.recurrenceReviewReason { throw Self.failure(reason) }
        let rule: String?
        switch task.frequency {
        case .once, .anytime: rule = nil
        case .daily: rule = Self.canonical(frequency: "DAILY", interval: 1, days: nil, monthDay: nil, last: false, weekStart: 2, until: task.recurrenceUntil)
        case .weekly: rule = Self.canonical(frequency: "WEEKLY", interval: task.weeklyStep, days: task.weekdays, monthDay: nil, last: false, weekStart: task.recurrenceWeekStart ?? 2, until: task.recurrenceUntil)
        case .monthly: rule = Self.canonical(frequency: "MONTHLY", interval: task.monthlyStep, days: nil, monthDay: task.monthlyDay ?? Calendar.current.component(.day, from: task.recurrenceAnchor ?? task.date), last: task.monthlyOnLastDay == true, weekStart: 2, until: task.recurrenceUntil)
        case .custom:
            guard task.unit == .days || task.unit == .weeks else { throw Self.failure("This custom interval cannot be written to Apple Reminders exactly") }
            rule = Self.canonical(frequency: task.unit == .days ? "DAILY" : "WEEKLY", interval: max(1, task.interval), days: task.unit == .weeks ? [Calendar.current.component(.weekday, from: task.recurrenceAnchor ?? task.date)] : nil, monthDay: nil, last: false, weekStart: 2, until: task.recurrenceUntil)
        case .flexible: rule = nil
        }
        let due = task.isUnscheduled || task.hasDueDate == false ? nil : (task.isAllDay ? Calendar.current.startOfDay(for: task.date) : Self.minuteDate(task.date))
        return SyncedTaskValue(title: task.title, calendarID: calendarID, date: due, allDay: due == nil || task.isAllDay, completed: task.completed, rule: rule)
    }
    func value(_ item: EKReminder) throws -> SyncedTaskValue {
        let due = item.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let allDay = item.dueDateComponents?.hour == nil || (due.map { Calendar.current.component(.hour, from: $0) == 0 && Calendar.current.component(.minute, from: $0) == 0 } ?? true)
        var rule: String?
        if let rules = item.recurrenceRules, !rules.isEmpty {
            guard rules.count == 1, let anchor = due else { throw Self.failure("This Apple recurrence needs review") }
            let parsed = try Reminder.ImportedRule.parse(rules[0].description)
            rule = Self.canonical(frequency: parsed.frequency, interval: parsed.interval, days: parsed.frequency == "WEEKLY" ? (parsed.days ?? [Calendar.current.component(.weekday, from: anchor)]) : nil, monthDay: parsed.monthDay ?? Calendar.current.component(.day, from: anchor), last: parsed.lastDay, weekStart: parsed.weekStart, until: parsed.until)
        }
        return SyncedTaskValue(title: item.title ?? "", calendarID: item.calendar.calendarIdentifier, date: due.map { allDay ? Calendar.current.startOfDay(for: $0) : Self.minuteDate($0) }, allDay: allDay, completed: item.isCompleted, rule: rule)
    }
    func apply(_ value: SyncedTaskValue, to task: inout Reminder, source: EKReminder, owner: Reminder.Owner) {
        task.title = value.title
        task.list = Self.listName(source.calendar.title)
        task.owner = owner
        task.hasDueDate = value.date != nil
        task.allDay = value.allDay
        task.date = value.date ?? .distantPast
        task.completed = value.completed
        if value.completed { task.deferredUntil = nil; task.deferredBeforeCompletion = nil }
        task.sourceID = source.calendarItemIdentifier
        task.appleReminderExternalID = source.calendarItemExternalIdentifier
        task.appleReminderCalendarID = value.calendarID
        task.deletedAt = nil
        task.notesMigrationVersion = task.notesMigrationVersion ?? 2 // Reminders' note text is not a HouseHippo linked note.
        task.listRulesVersion = 1
        task.recurrenceImportVersion = nil
        task.originalRecurrenceRule = value.rule
        task.recurrenceReviewReason = nil
        task.recurrenceAnchor = value.date
        task.selectedWeekdays = nil; task.weeklyEvery = nil; task.monthlyEvery = nil; task.monthlyDay = nil; task.monthlyOnLastDay = nil; task.recurrenceUntil = nil
        task.frequency = value.date == nil ? .anytime : .once
        if value.rule != nil { task.matchImportedRecurrence(respectFlexibleLists: false) }
        else { task.recurrenceImportVersion = 1 }
        if let completion = source.completionDate, completion != task.lastCompleted {
            task.dateBeforeCompletion = nil
            task.lastCompleted = completion
            if !task.history.contains(completion) { task.history.append(completion) }
        }
    }
    func update(_ source: EKReminder, expected: SyncedTaskValue, desired: SyncedTaskValue, completionDate: Date? = nil) throws -> EKReminder {
        try write("update reminder", movingLists: expected.calendarID != desired.calendarID) { store in
            guard let current = store.calendarItem(withIdentifier: source.calendarItemIdentifier) as? EKReminder, try value(current) == expected else { throw Self.failure("Reminder changed during sync; retrying without overwriting it") }
            try set(desired, on: current, in: store, previous: expected)
            if desired.completed, let completionDate { current.completionDate = completionDate }
            try store.save(current, commit: true)
            return current
        }
    }
    func create(taskID: UUID, desired: SyncedTaskValue) throws -> EKReminder {
        try write("create reminder") { store in
            let item = EKReminder(eventStore: store)
            item.url = URL(string: "househippo://task/" + taskID.uuidString)
            try set(desired, on: item, in: store)
            try store.save(item, commit: true)
            return item
        }
    }
    func complete(_ source: EKReminder, expected: SyncedTaskValue, date: Date) throws {
        try write("complete reminder") { store in
            guard let current = store.calendarItem(withIdentifier: source.calendarItemIdentifier) as? EKReminder, try value(current) == expected else { throw Self.failure("Reminder changed before completion") }
            current.isCompleted = true; current.completionDate = date
            try store.save(current, commit: true)
        }
    }
    func delete(_ source: EKReminder, expected: SyncedTaskValue) throws {
        try write("delete reminder") { store in
            guard let current = store.calendarItem(withIdentifier: source.calendarItemIdentifier) as? EKReminder, try value(current) == expected else { throw Self.failure("Reminder changed before deletion") }
            try store.remove(current, commit: true)
        }
    }
    private func set(_ value: SyncedTaskValue, on item: EKReminder, in store: EKEventStore, previous: SyncedTaskValue? = nil) throws {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == value.calendarID && $0.allowsContentModifications }) else { throw Self.failure("Destination list is unavailable") }
        let recurrenceChanged = previous == nil || previous?.rule != value.rule
        var replacementRule: EKRecurrenceRule?
        if recurrenceChanged, let raw = value.rule {
            let rule = try Reminder.ImportedRule.parse(raw)
            if rule.frequency == "WEEKLY" && rule.weekStart != 2 { throw Self.failure("This week-start rule cannot be written exactly") }
            let end = rule.until.map { EKRecurrenceEnd(end: $0) }
            let frequency: EKRecurrenceFrequency = rule.frequency == "DAILY" ? .daily : rule.frequency == "WEEKLY" ? .weekly : .monthly
            let days = rule.days?.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
            let monthDays = rule.frequency == "MONTHLY" ? [NSNumber(value: rule.lastDay ? -1 : (rule.monthDay ?? Calendar.current.component(.day, from: value.date ?? Date())))] : nil
            replacementRule = EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days, daysOfTheMonth: monthDays, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
        }
        // Validate first. Change only edited transferable fields; never alter note text, URLs, alarms or attachments.
        if previous?.title != value.title { item.title = value.title }
        if previous?.calendarID != value.calendarID { item.calendar = calendar }
        if previous == nil || previous?.date != value.date || previous?.allDay != value.allDay {
            item.dueDateComponents = value.date.map { Calendar.current.dateComponents(value.allDay ? [.year,.month,.day] : [.year,.month,.day,.hour,.minute], from: $0) }
        }
        if item.isCompleted != value.completed { item.isCompleted = value.completed }
        if recurrenceChanged { item.recurrenceRules = replacementRule.map { [$0] } }
    }
    nonisolated private static func canonical(frequency: String, interval: Int, days: [Int]?, monthDay: Int?, last: Bool, weekStart: Int, until: Date?) -> String {
        var result = "RRULE FREQ=\(frequency);INTERVAL=\(interval)"
        if frequency == "WEEKLY", let days {
            let codes = ["SU","MO","TU","WE","TH","FR","SA"]
            result += ";BYDAY=" + days.sorted().map { codes[$0-1] }.joined(separator: ",")
            if weekStart != 2 { result += ";WKST=" + codes[weekStart-1] }
        }
        if frequency == "MONTHLY" { result += ";BYMONTHDAY=" + String(last ? -1 : (monthDay ?? 1)) }
        if let until {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            result += ";UNTIL=" + format.string(from: until)
        }
        return result
    }
    nonisolated private static func minuteDate(_ date: Date) -> Date { Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60) }
    nonisolated private static func failure(_ text: String) -> NSError { NSError(domain: "HouseHippo.RemindersSync", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
}
