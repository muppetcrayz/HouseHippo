import SwiftUI
import UserNotifications
import EventKit
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
import BackgroundTasks
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
    var shortcutName: String?
    var shortcutURL: URL? {
        guard isNotification, let name = shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }
    var shouldNotify: Bool { isNotification && enabled && !completed && frequency != .anytime && hasDueDate != false }
    func shouldNotify(on person: Owner) -> Bool {
        shouldNotify && (owner == .shared || owner == person)
    }
    static var devicePerson: Owner {
        let stored = HouseHippoRuntime.defaults.string(forKey: "househippo.person")
        let person = stored.flatMap(Owner.init(rawValue:)) ?? .me
        return person == .shared ? .me : person
    }
    var owner: Owner = .shared
    // Retain original imported text for recovery; taskNote is the editable task content.
    var notes: String = ""
    var taskNote: String?
    var linkedNoteID: UUID? // Legacy migration only; never offered as a note picker.
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
        guard isDueToday(at: now) || (!isNotification && isOverdue(at: now)) else { return false }
        if isOverdue(at: now) { return true }
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
    static func flexibleOrderedBefore(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        // Keep each person's tasks together, before shared household tasks.
        func ownerOrder(_ owner: Owner) -> Int {
            switch owner { case .me: return 0; case .husband: return 1; case .shared: return 2 }
        }
        let lhsOwner = ownerOrder(lhs.owner), rhsOwner = ownerOrder(rhs.owner)
        if lhsOwner != rhsOwner { return lhsOwner < rhsOwner }
        let listOrder = lhs.list.localizedStandardCompare(rhs.list)
        if listOrder != .orderedSame { return listOrder == .orderedAscending }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    static func dashboardOrderedBefore(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        let lhsAllDay = lhs.isAllDay || lhs.isFlexibleTask
        let rhsAllDay = rhs.isAllDay || rhs.isFlexibleTask
        if lhsAllDay != rhsAllDay { return lhsAllDay }
        if !lhsAllDay {
            let calendar = Calendar.current
            let lhsTime = calendar.component(.hour, from: lhs.effectiveDate) * 60 + calendar.component(.minute, from: lhs.effectiveDate)
            let rhsTime = calendar.component(.hour, from: rhs.effectiveDate) * 60 + calendar.component(.minute, from: rhs.effectiveDate)
            if lhsTime != rhsTime { return lhsTime < rhsTime }
        }
        let listOrder = lhs.list.localizedStandardCompare(rhs.list)
        if listOrder != .orderedSame { return listOrder == .orderedAscending }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    static func orderedBefore(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    func isOverdue(at now: Date = Date()) -> Bool {
        guard !completed, deletedAt == nil else { return false }
        // Daily notifications schedule another alert; they do not become overdue tasks.
        if isNotification && frequency == .daily { return false }
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
        case .custom: return "Every \(interval) \(unit.rawValue)\(timeSuffix)"
        }
    }
}

struct NoteParagraph: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var style = "body"
    var depth = 0
}

struct HouseNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var archived: Bool?
    var deletedAt: Date?
    var sourceTaskID: UUID?
    var paragraphs: [NoteParagraph]?
    var appleNotesSourceID: String?
    var appleNotesBodyIsCanonical: Bool?
    var appleNotesOriginalHTML: String?
    var appleNotesFolder: String?
    var appleNotesAttachmentCount: Int?
    var markdownText: String {
        guard let paragraphs else { return body }
        return paragraphs.map { paragraph in
            let prefix: String
            switch paragraph.style {
            case "h1": prefix = "# "
            case "h2": prefix = "## "
            case "bullet": prefix = String(repeating: "  ", count: max(0, min(6, paragraph.depth))) + "- "
            default: prefix = ""
            }
            return prefix + paragraph.text
        }.joined(separator: "\n")
    }
    /// Only flat Markdown lists with plain item text qualify as random-choice lists.
    static func randomItems(in markdown: String) -> [String]? {
        var items: [String] = []
        var listKind: String?
        for rawLine in markdown.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // Indentation can represent a nested list or code, neither is a plain list.
            guard rawLine.first != " ", rawLine.first != "\t",
                  let match = rawLine.range(of: #"^(?:[-*+•] |[0-9]+[.)] )"#, options: .regularExpression) else { return nil }
            let kind = rawLine.first?.isNumber == true ? "ordered" : String(rawLine.first!)
            if let listKind, listKind != kind { return nil }
            listKind = kind
            let item = String(rawLine[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty,
                  item.range(of: #"[*_`\[\]<>]|!\(|^#{1,6} |^> |^[-+•] |^[0-9]+[.)] |^[-=]{3,}$| {2}$"#, options: .regularExpression) == nil else { return nil }
            items.append(item)
        }
        return items.isEmpty ? nil : items
    }
    var randomItems: [String]? { Self.randomItems(in: markdownText) }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title }
}

struct WaitingRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var deletedAt: Date?
}

struct WaitingUpdate: Identifiable, Codable, Equatable {
    var id = UUID()
    var recordID: UUID
    var text: String
    var date = Date()
    var deletedAt: Date?
    func flexibleTask(recordTitle: String, owner: Reminder.Owner) -> Reminder {
        var task = Reminder(title: text, message: "", date: Date(), frequency: .anytime)
        task.kind = .task
        task.hasDueDate = false
        task.owner = owner
        task.list = owner == .shared ? "One-off general tasks" : "One-off personal tasks"
        task.taskNote = "Waiting For: \(recordTitle)\n\(date.formatted(date: .abbreviated, time: .shortened))\n\(text)"
        return task
    }
}

struct BorrowedItem: Identifiable, Codable, Equatable {
    enum Direction: String, Codable, CaseIterable {
        case borrowing, lending
        var label: String { self == .borrowing ? "I have theirs" : "They have mine" }
    }
    var id = UUID()
    var person: String
    var item: String
    var direction: Direction
    var returnedAt: Date?
    var deletedAt: Date?
}

/// Money is stored in cents; positive means the other person owes me.
struct MoneyEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var person: String
    var title: String
    var day: String
    var cents: Int
    var deletedAt: Date?

    static func amount(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression), match == value.startIndex..<value.endIndex,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              abs(decimal) <= 1_000_000_000 else { return nil }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }
    static func money(_ cents: Int, signed: Bool = false) -> String {
        (cents < 0 ? "-" : signed ? "+" : "") + String(format: "$%lld.%02lld", Int64(abs(cents) / 100), Int64(abs(cents) % 100))
    }
    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    var date: Date {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day) ?? Date()
    }
    static func ordered(_ entries: [MoneyEntry]) -> [MoneyEntry] {
        entries.sorted { $0.day == $1.day ? $0.id.uuidString < $1.id.uuidString : $0.day < $1.day }
    }
    static func balance(_ entries: [MoneyEntry]) -> Int { entries.reduce(0) { $0 + $1.cents } }
    static func paymentCents(_ amount: Int, balance: Int) -> Int? {
        guard amount > 0, amount <= abs(balance) else { return nil }
        return balance > 0 ? -amount : amount
    }
    static func summary(person: String, entries: [MoneyEntry]) -> String {
        let total = balance(entries)
        let heading = total > 0 ? "You owe me \(money(total))." : total < 0 ? "I owe you \(money(-total))." : "We’re settled up."
        return "\(person) — \(heading)\n+ = you owe me; − = I owe you\n\n" + ordered(entries).map {
            "\($0.day) - \($0.title) - \(money($0.cents, signed: true))"
        }.joined(separator: "\n") + "\n\nNet total: \(money(total, signed: true))"
    }
    enum ImportError: LocalizedError {
        case line(Int)
        var errorDescription: String? {
            switch self { case .line(let number): return "Check line \(number). Use M/D - Description - +12.34 (or -12.34)." }
        }
    }
    static func parse(_ text: String, person: String, year: Int) throws -> [MoneyEntry] {
        var entries: [MoneyEntry] = []
        let regex = try NSRegularExpression(pattern: #"^(\d{1,2})/(\d{1,2})\s+-\s+(.+?)\s+-\s+([+-]?[0-9]+(?:\.[0-9]{1,2})?)$"#)
        let calendar = Calendar(identifier: .gregorian)
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // A standalone total in a pasted list is informational, never another charge.
            if amount(line) != nil { continue }
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let month = Int(ns.substring(with: match.range(at: 1))),
                  let day = Int(ns.substring(with: match.range(at: 2))),
                  let cents = amount(ns.substring(with: match.range(at: 4))), cents != 0,
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { throw ImportError.line(index + 1) }
            entries.append(MoneyEntry(person: person, title: ns.substring(with: match.range(at: 3)), day: dayString(date), cents: cents))
        }
        guard !entries.isEmpty else { throw ImportError.line(1) }
        return entries
    }
}

struct PaymentDue: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var cents: Int
    var day: String
    var notes = ""
    var paidAt: Date?
    var deletedAt: Date?
    var date: Date { MoneyEntry(person: "", title: "", day: day, cents: 0).date }
    enum DueGroup: String, CaseIterable {
        case overdue = "Overdue", today = "Due today", soon = "Next 7 days", later = "Later", paid = "Paid"
    }
    func group(today: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> DueGroup {
        if paidAt != nil { return .paid }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 0 { return .overdue }
        if days == 0 { return .today }
        return days <= 7 ? .soon : .later
    }
}

struct RecurringBill: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var cents: Int
    var day: String
    var yearly = false
    var interval = 1
    var count: Int?
    var until: String?
    var excluded: [String] = []
    var sourceUID: String?
    var notes = ""
    var deletedAt: Date?
    var date: Date { MoneyEntry(person: "", title: "", day: day, cents: 0).date }
    func occurrences(from start: Date, to end: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
        let anchor = calendar.startOfDay(for: date)
        guard anchor < end, start < end else { return [] }
        let limit = until.map { MoneyEntry(person: "", title: "", day: $0, cents: 0).date }
        if let limit, limit < start { return [] }
        let targetDay = calendar.component(.day, from: anchor)
        let firstMonth = calendar.dateInterval(of: .month, for: anchor)!.start
        let months = max(0, calendar.dateComponents([.month], from: firstMonth, to: end).month ?? 0)
        let step = max(1, interval) * (yearly ? 12 : 1)
        let startMonth = calendar.dateInterval(of: .month, for: start)!.start
        let elapsed = max(0, calendar.dateComponents([.month], from: firstMonth, to: startMonth).month ?? 0)
        // COUNT needs the historical occurrence count; unlimited series jump to the requested month.
        let firstOffset = count == nil ? (elapsed / step) * step : 0
        var dates: [Date] = []; var occurrence = 0
        for offset in stride(from: firstOffset, through: months, by: step) {
            guard let month = calendar.date(byAdding: .month, value: offset, to: firstMonth),
                  let range = calendar.range(of: .day, in: .month, for: month), range.contains(targetDay),
                  let candidate = calendar.date(byAdding: .day, value: targetDay - 1, to: month) else { continue }
            occurrence += 1
            if let count, occurrence > count { break }
            if let limit, candidate > limit { break }
            // Format only occurrences inside the requested range, never the full history.
            if candidate >= start && candidate < end && (excluded.isEmpty || !excluded.contains(MoneyEntry.dayString(candidate))) { dates.append(candidate) }
        }
        return dates
    }
    // The requested budget year is fixed, so old imports stay archived as time passes.
    static var budgetYearStart: Date { MoneyEntry(person: "", title: "", day: "2026-11-01", cents: 0).date }
    static var budgetYearEnd: Date { MoneyEntry(person: "", title: "", day: "2027-11-01", cents: 0).date }
    var isActiveInBudgetYear: Bool {
        !occurrences(from: Self.budgetYearStart, to: Self.budgetYearEnd).isEmpty
    }
    static func periodStart(containing date: Date, anchor: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        let first = calendar.startOfDay(for: anchor)
        let days = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? 0
        return calendar.date(byAdding: .day, value: Int(floor(Double(days) / 14)) * 14, to: first)!
    }
}

/// A deliberately bounded importer: unsupported rules are reported rather than approximated.
enum BillCalendarImport {
    struct Preview: Sendable { var bills: [RecurringBill]; var warnings: [String]; var inactiveCount = 0 }
    static func load(_ url: URL) async throws -> Preview {
        let worker = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25_000_000 else {
                throw NSError(domain: "HouseHippo.Bills", code: 2, userInfo: [NSLocalizedDescriptionKey: "This calendar is too large. Export just the bills calendar (up to 25 MB)."])
            }
            try Task.checkCancellation()
            return try parse(String(contentsOf: url, encoding: .utf8))
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func parse(_ text: String) throws -> Preview {
        func invalid(_ text: String) -> NSError { NSError(domain: "HouseHippo.Bills", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard text.contains("BEGIN:VCALENDAR"), text.contains("END:VCALENDAR") else { throw invalid("Choose an exported .ics calendar file.") }
        var lines: [String] = []
        try Task.checkCancellation()
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else { lines.append(line) }
        }
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
        }
        func day(_ raw: String) -> String? {
            let value = String(raw.prefix(8))
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyyMMdd"; f.isLenient = false
            guard let date = f.date(from: value), f.string(from: date) == value else { return nil }
            return MoneyEntry.dayString(date)
        }
        var events: [[String: [String]]] = []; var event: [String: [String]]?; var alarm = false
        for line in lines {
            if line == "BEGIN:VEVENT" { event = [:]; continue }
            if line == "END:VEVENT" { if let event { events.append(event) }; event = nil; continue }
            if line == "BEGIN:VALARM" { alarm = true; continue }
            if line == "END:VALARM" { alarm = false; continue }
            guard event != nil, !alarm, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon].split(separator: ";")[0])
            event![key, default: []].append(String(line[line.index(after: colon)...]))
        }
        let changedUIDs = Set(events.filter { $0["RECURRENCE-ID"] != nil }.compactMap { $0["UID"]?.first })
        var bills: [RecurringBill] = []; var warnings: [String] = []; var seen = Set<String>(); var inactiveCount = 0
        for event in events {
            try Task.checkCancellation()
            let title = unescape(event["SUMMARY"]?.first ?? "Untitled bill")
            do {
                guard event["RECURRENCE-ID"] == nil else { continue }
                guard event["STATUS"]?.first != "CANCELLED" else { continue }
                guard let uid = event["UID"]?.first, !uid.isEmpty, seen.insert(uid).inserted else { throw invalid("Missing or duplicate calendar identity") }
                guard !changedUIDs.contains(uid) else { throw invalid("Series has changed individual occurrences; review it manually") }
                guard let raw = event["DTSTART"]?.first, let start = day(raw) else { throw invalid("Missing or invalid start date") }
                guard let rules = event["RRULE"], rules.count == 1, event["RDATE"] == nil, event["EXRULE"] == nil else { throw invalid("Only monthly and yearly recurring bills are imported") }
                var fields: [String: String] = [:]
                for pair in rules[0].split(separator: ";") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, fields[String(parts[0])] == nil else { throw invalid("Invalid repeat rule") }
                    fields[String(parts[0])] = String(parts[1])
                }
                guard Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTHDAY", "BYMONTH", "WKST"]),
                      ["MONTHLY", "YEARLY"].contains(fields["FREQ"] ?? ""),
                      let interval = Int(fields["INTERVAL"] ?? "1"), (1...120).contains(interval),
                      fields["BYMONTHDAY"] == nil || Int(fields["BYMONTHDAY"]!) == Int(start.suffix(2)),
                      fields["BYMONTH"] == nil || (fields["FREQ"] == "YEARLY" && Int(fields["BYMONTH"]!) == Int(start.dropFirst(5).prefix(2))) else { throw invalid("Unsupported repeat pattern; review it manually") }
                var bill = RecurringBill(title: title, cents: 0, day: start, yearly: fields["FREQ"] == "YEARLY", interval: interval)
                if let raw = fields["COUNT"] { guard let count = Int(raw), count > 0 else { throw invalid("Invalid repeat count") }; bill.count = count }
                if let raw = fields["UNTIL"] { guard let end = day(raw) else { throw invalid("Invalid repeat end") }; bill.until = end }
                guard bill.count == nil || bill.until == nil else { throw invalid("Rule has both count and end") }
                for raw in event["EXDATE"] ?? [] {
                    for value in raw.split(separator: ",") { guard let date = day(String(value)) else { throw invalid("Invalid excluded date") }; bill.excluded.append(date) }
                }
                bill.sourceUID = uid; bill.notes = unescape(event["DESCRIPTION"]?.first ?? "")
                // A trailing period or comma ends the sentence; a digit after either means a longer number.
                let regex = try NSRegularExpression(pattern: #"\$\s*((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?)(?![0-9]|[.,][0-9])"#)
                let ns = (title + "\n" + bill.notes) as NSString
                let matches = regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
                if matches.count == 1 { bill.cents = MoneyEntry.amount(ns.substring(with: matches[0].range(at: 1)).replacingOccurrences(of: ",", with: "")) ?? 0 }
                if bill.isActiveInBudgetYear { bills.append(bill) } else { inactiveCount += 1 }
            } catch { warnings.append("\(title): \(error.localizedDescription)") }
        }
        return Preview(bills: bills, warnings: warnings, inactiveCount: inactiveCount)
    }
}

struct BudgetPaycheck: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var useActualAmount = true
    var actualAmount = ""
    var hours = ""
    var hourlyRate = ""
    var takeHomePercent = "100"

    static func number(_ text: String, maximum: Decimal, places: Int = 6) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,\(places)})?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value >= 0, value <= maximum else { return nil }
        return value
    }
    var netAmount: Decimal? {
        if useActualAmount {
            guard let cents = MoneyEntry.amount(actualAmount), cents >= 0 else { return nil }
            return Decimal(cents) / 100
        }
        guard let hours = Self.number(hours, maximum: 10000, places: 4),
              let rate = Self.number(hourlyRate, maximum: 1_000_000, places: 2),
              let percent = Self.number(takeHomePercent, maximum: 100) else { return nil }
        return hours * rate * percent / 100
    }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && netAmount != nil }
    static func roundedCents(_ value: Decimal) -> Int {
        var cents = value * 100; var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
    static func estimate(for person: String) -> BudgetPaycheck {
        // Editable starting assumptions from the supplied Numbers paycheck calculator.
        BudgetPaycheck(name: person, useActualAmount: false, hourlyRate: person == "Dan" ? "46.88" : "50.98", takeHomePercent: person == "Dan" ? "89.574445" : "82.402603")
    }
}

struct PayPeriodBudget: Identifiable, Codable, Equatable {
    var id: String { startDay }
    var startDay: String
    var paychecks: [BudgetPaycheck] = []
    var additionalDebtCents = 0
    var investmentCents = 2500
    var savingsCents = 0
    var carryoverCents = 0
    var includePriorCarryover = true
    var notes = ""
    var incomeCents: Int? {
        guard !paychecks.isEmpty, paychecks.allSatisfy(\.isValid) else { return nil }
        // Numbers sums unrounded estimates, then formats the total to cents.
        return BudgetPaycheck.roundedCents(paychecks.reduce(Decimal(0)) { $0 + $1.netAmount! })
    }
    func totalIncomeCents(priorCarryoverCents: Int) -> Int? {
        incomeCents.map { $0 + (includePriorCarryover ? priorCarryoverCents : 0) }
    }
    func freeSpendingCents(billsCents: Int, priorCarryoverCents: Int = 0) -> Int? {
        totalIncomeCents(priorCarryoverCents: priorCarryoverCents).map { $0 - billsCents - additionalDebtCents - investmentCents - savingsCents - carryoverCents }
    }
}

struct LastTimeEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var owner: Reminder.Owner? // Older markers default to Shared.
    var assignedTo: Reminder.Owner { owner ?? .shared }
    func isVisible(to person: Reminder.Owner) -> Bool { assignedTo == .shared || assignedTo == person }
    // Store a calendar date, so changing time zones cannot move a marker to another day.
    var year: Int
    var month: Int
    var day: Int
    var deletedAt: Date?
    init(title: String, date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.title = title
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year!; month = parts.month!; day = parts.day!
    }
    func date(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    mutating func setDate(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year!; month = parts.month!; day = parts.day!
    }
    func elapsed(since now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let start = date(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days < 0 { return "In the future" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let parts = calendar.dateComponents([.year, .month], from: start, to: today)
        if let years = parts.year, years > 0 { return years == 1 ? "About a year ago" : "About \(years) years ago" }
        if let months = parts.month, months > 0 { return months == 1 ? "About a month ago" : "About \(months) months ago" }
        if days >= 7 { let weeks = days / 7; return weeks == 1 ? "About a week ago" : "About \(weeks) weeks ago" }
        return "\(days) days ago"
    }
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
    var paragraphs: [NoteParagraph]?
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

/// Debug UI tests get their own persistent store and preference domain on every run.
enum HouseHippoRuntime {
    static let testID: UUID? = {
        #if HOUSEHIPPO_UI_TESTING
        // Running this configuration manually must also stay out of live storage.
        return ProcessInfo.processInfo.environment["HOUSEHIPPO_UI_TEST_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()
        #elseif DEBUG
        return ProcessInfo.processInfo.environment["HOUSEHIPPO_UI_TEST_ID"].flatMap(UUID.init(uuidString:))
        #else
        return nil
        #endif
    }()
    static var isUITesting: Bool { testID != nil }
    static var storeDirectory: URL? {
        testID.map { FileManager.default.temporaryDirectory.appendingPathComponent("HouseHippo-UITests/" + $0.uuidString, isDirectory: true) }
    }
    static let defaults: UserDefaults = {
        guard let testID else { return .standard }
        return UserDefaults(suiteName: "HouseHippo.UITests." + testID.uuidString)!
    }()
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = NotificationDelegate()
    @MainActor private var pendingShortcutURL: URL?
    @MainActor func openPendingShortcut() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active, let url = pendingShortcutURL else { return }
        pendingShortcutURL = nil
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                Task { @MainActor in
                    self.openError = "Could not open Shortcuts. Install Apple's Shortcuts app and try again."
                }
            }
        }
        #endif
    }
    @MainActor @Published var openError: String?
    // Use explicit callbacks so the system's completion always runs on the main
    // queue. The async bridge can resume on a background executor after a tap.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let name = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.userInfo["shortcutName"] as? String : nil
        DispatchQueue.main.async {
            if let name {
                var reminder = Reminder(title: "", message: "", date: Date(), frequency: .once)
                reminder.kind = .notification
                reminder.shortcutName = name
                self.pendingShortcutURL = reminder.shortcutURL
            }
            completionHandler()
            // Let iOS finish processing the response before leaving HouseHippo.
            DispatchQueue.main.async { self.openPendingShortcut() }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            #if os(iOS)
            completionHandler([.banner, .list, .sound])
            #else
            completionHandler([])
            #endif
        }
    }
}

@MainActor final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
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
        if HouseHippoRuntime.isUITesting { reloadTasks(); return }
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
    @discardableResult
    func convertToWaitingFor(_ reminder: Reminder) async -> Bool {
        do {
            try cloud.convertToWaitingFor(reminder)
            reloadTasks()
            await schedule()
            return true
        } catch {
            self.error = "Could not convert task: " + error.localizedDescription
            return false
        }
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
    func moveToNextRepeat(_ reminder: Reminder) async {
        guard var current = reminders.first(where: { $0.id == reminder.id }) else { return }
        current.moveToNextRepeat()
        await save(current)
    }
    func moveBackToToday(_ reminder: Reminder) async {
        guard var current = reminders.first(where: { $0.id == reminder.id }) else { return }
        current.moveBackToToday()
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
                if let embedded = task.taskNote { noteText = embedded }
                else if let id = task.linkedNoteID { noteText = try cloud.note(id: id)?.body }
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
        guard !HouseHippoRuntime.isUITesting else { return }
        await cloud.checkAccount()
        #if os(iOS)
        status = await center.notificationSettings().authorizationStatus
        #endif
        await schedule()
    }
    func requestPermission() async {
        guard !HouseHippoRuntime.isUITesting else { return }
        #if os(iOS)
        do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]); await refresh() }
        catch { self.error = error.localizedDescription }
        #endif
    }
    private func schedule() async {
        guard !HouseHippoRuntime.isUITesting else { return }
        coverage = nil
        #if os(macOS)
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        #else
        guard status == .authorized || status == .provisional else { center.removeAllPendingNotificationRequests(); return }
        let person = Reminder.devicePerson
        let now = Date()
        let active = reminders.filter { $0.shouldNotify(on: person) && ($0.frequency != .once || $0.date > now) }
        // Native repeating triggers match only the clock time and weekday/day, so a repeat
        // that has not started yet is scheduled date by date until its start passes.
        func rolling(_ reminder: Reminder) -> Bool { reminder.usesRollingNotifications || (reminder.frequency != .once && reminder.date > now) }
        // Reserve one request per native repeating reminder; share the remainder across custom schedules.
        let custom = active.filter(rolling)
        let native = active.filter { !rolling($0) }
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
                if reminder.shortcutURL != nil {
                    content.userInfo["shortcutName"] = reminder.shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if rolling(reminder) {
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
        // Start from the reminder's own date when it is later, so nothing fires before it starts.
        // Weekly and monthly occurrences fall on the whole minute, so start at that minute.
        let start = Calendar.current.dateInterval(of: .minute, for: reminder.date)?.start ?? reminder.date
        var cursor = max(Date(), start.addingTimeInterval(-1))
        var result: [Date] = []
        for _ in 0..<max(0, count) {
            guard let next = reminder.nextScheduledOccurrence(after: cursor) else { break }
            result.append(next); cursor = next
        }
        return result
    }
}

#if !HOUSEHIPPO_TESTING
@main struct HouseHippoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HouseHippoDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(HouseHippoDelegate.self) private var delegate
    #endif
    @StateObject private var store = ReminderStore.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            HouseHippoHome().environmentObject(store).defaultAppStorage(HouseHippoRuntime.defaults)
                .overlay(alignment: .bottomLeading) {
                    if HouseHippoRuntime.isUITesting {
                        Text("Isolated UI test household").font(.caption2).padding(4)
                            .background(.background).accessibilityIdentifier("househippo-ui-test-household")
                    }
                }
                .task { NotificationDelegate.shared.openPendingShortcut(); AppleSyncService.shared.start(); await store.refresh() }
                .onChange(of: phase) { _, value in
                    switch value {
                    case .active: NotificationDelegate.shared.openPendingShortcut(); AppleSyncService.shared.request(); Task { await store.refresh() }
                    #if os(iOS)
                    case .background: BackgroundRefresh.schedule()
                    #endif
                    default: break
                    }
                }
                .frame(minWidth: 340, minHeight: 500)
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await BackgroundRefresh.run()
        }
        #endif
    }
}
#endif

#if os(iOS)
/// Wakes the app periodically so iCloud changes are downloaded before it is opened.
/// iOS decides when this runs, based on how often the app is used.
enum BackgroundRefresh {
    static let identifier = "com.danturner.HouseHippo.refresh"
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Fails in the simulator and when Background App Refresh is off; foreground sync still works.
        try? BGTaskScheduler.shared.submit(request)
    }
    @MainActor static func run() async {
        await CloudStore.shared.waitForImport()
        // Give Core Data a moment to merge the import into the view context before reading.
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        // Reload tasks and extend rolling notification coverage.
        await ReminderStore.shared.refresh()
    }
}
#endif

struct HouseHippoHome: View {
    @ObservedObject private var notificationDelegate = NotificationDelegate.shared
    @EnvironmentObject private var store: ReminderStore
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var selectedTab = 2
    @State private var taskScope = "Active"
    @State private var completedTasksRequest = 0
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
                        Section("Life Management") {
                            Label("Waiting For", systemImage: "clock").tag(6)
                            Label("Borrowing & Lending", systemImage: "arrow.left.arrow.right").tag(7)
                            Label("Last Time", systemImage: "calendar.badge.clock").tag(8)
                            Label("Inventory", systemImage: "archivebox").tag(9)
                            Label("Things To Pay", systemImage: "creditcard").tag(10)
                        }
                        Label("Notes", systemImage: "note.text").tag(11)
                        Label("Meals", systemImage: "fork.knife").tag(5)
                    }.listStyle(.sidebar)
                }.navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 250)
            } detail: {
                switch selectedTab {
                case 1: TaskList(scope: $taskScope, completedTasksRequest: completedTasksRequest, mode: .tasks)
                case 6: NavigationStack { WaitingForView() }
                case 7: NavigationStack { BorrowingLendingView() }
                case 8: NavigationStack { LastTimeView() }
                case 9: InventoryView()
                case 10: NavigationStack { ThingsToPayView() }
                case 11: NavigationStack { NotesHome() }
                case 2: HomeDashboard(navigate: { selectedTab = $0 }, showCompletedTasks: showCompletedTasks)
                default: MealsView()
                }
            }.navigationSplitViewStyle(.balanced)
            #else
        TabView(selection: $selectedTab) {
            TaskList(scope: .constant("Active"), mode: .notifications).tabItem { Label("Notifications", systemImage: "bell") }.tag(0)
            TaskList(scope: $taskScope, completedTasksRequest: completedTasksRequest, mode: .tasks).tabItem { Label("Tasks", systemImage: "checklist") }.tag(1)
            HomeDashboard(navigate: { selectedTab = $0 }, showCompletedTasks: showCompletedTasks).tabItem { Label("Dashboard", systemImage: "house") }.tag(2)
            LifeHubView().tabItem { Label("Life", systemImage: "square.grid.2x2") }.tag(6)
            MealsView().tabItem { Label("Meals", systemImage: "fork.knife") }.tag(5)
        }
            #endif
        }
        .tint(.teal)
        .onChange(of: person) { _, _ in Task { await store.refresh() } }
        .alert("HouseHippo", isPresented: Binding(get: { store.error != nil || store.transferStatus != nil || notificationDelegate.openError != nil }, set: { if !$0 { store.error = nil; store.transferStatus = nil; notificationDelegate.openError = nil } })) {
            Button("OK") { store.error = nil; store.transferStatus = nil; notificationDelegate.openError = nil }
        } message: { Text(store.error ?? store.transferStatus ?? notificationDelegate.openError ?? "") }
    }
    private func showCompletedTasks() {
        taskScope = "Completed"
        completedTasksRequest += 1
        selectedTab = 1
    }

}

enum TaskMode { case tasks, notifications }
struct TaskList: View {
    @EnvironmentObject private var store: ReminderStore
    @AppStorage("househippo.tasks.ownerFilter") private var ownerFilter = "All"
    @State private var search = ""
    @State private var editing: Reminder?
    @State private var randomPick: Reminder?
    @Binding var scope: String
    var completedTasksRequest = 0
    @State private var confirmExport = false
    @State private var importing = false
    @State private var now = Date()
    let mode: TaskMode
    private var completedScope: Bool { scope == "Completed" }
    private var filtered: [Reminder] {
        store.reminders.filter { task in
            let matchesOwner = mode != .tasks || (Reminder.Owner(rawValue: ownerFilter).map { task.owner == $0 } ?? true)
            let relevant = mode == .notifications ? task.isNotification : !task.isNotification
            let matches = search.isEmpty || (task.title + " " + task.list).localizedCaseInsensitiveContains(search)
            let inScope = completedScope ? (task.wasCompletedToday(at: now) || task.isDelayed(at: now)) : !task.completed
            return matchesOwner && relevant && matches && inScope
        }
    }
    var body: some View {
        let tasks = filtered
        return NavigationStack {
            HippoCanvas {
                HippoPageHeader(title: mode == .tasks ? "Tasks" : "Notifications", summary: summary(tasks)) {
                    if mode == .tasks {
                        Picker("For", selection: $ownerFilter) {
                            Text("Everyone").tag("All")
                            ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        Picker("Show", selection: $scope) { Text("Active").tag("Active"); Text("Done & delayed").tag("Completed") }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
                if mode == .notifications { deliveryCard }
                if tasks.isEmpty { emptyState }
                else if mode == .notifications {
                    VStack(alignment: .leading, spacing: 12) {
                        HippoSectionHeader("Your notifications", icon: "bell", count: tasks.count)
                        HippoGrid { ForEach(tasks) { card($0, accent: .teal) } }
                    }
                } else {
                    HippoGrid(minimum: 380, spacing: 28) {
                        if completedScope {
                            board("Done today", icon: "checkmark.circle", accent: .green, groups: [("", tasks.filter { $0.wasCompletedToday(at: now) && !$0.isDelayed(at: now) })])
                            board("Delayed", icon: "calendar.badge.clock", accent: .orange, groups: [("", tasks.filter { $0.isDelayed(at: now) })])
                        } else {
                            board("Scheduled", icon: "calendar", accent: .teal, groups: scheduledGroups(tasks.filter { !$0.isFlexibleTask }))
                            let flexible = tasks.filter(\.isFlexibleTask).sorted(by: Reminder.flexibleOrderedBefore)
                            board("Flexible", icon: "leaf", accent: .orange, groups: [
                                ("Ready any time", flexible.filter { $0.isAvailableFlexible(at: now) }),
                                ("Resting", flexible.filter { !$0.isAvailableFlexible(at: now) })
                            ], random: flexible.filter { $0.isAvailableFlexible(at: now) })
                        }
                    }
                }
            }
            .hippoCanvasPage(mode == .tasks ? "Tasks" : "Notifications")
            .searchable(text: $search, prompt: "Search tasks and lists")
            .onAppear { now = Date() }
            .onChange(of: completedTasksRequest) { _, _ in
                search = ""
                now = Date()
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button(mode == .notifications ? "Add notification" : "Add task", systemImage: "plus") {
                    var item = Reminder(title: "", message: "", date: Date().addingTimeInterval(3600), frequency: .once)
                    item.kind = mode == .notifications ? .notification : .task
                    item.allDay = mode != .notifications
                    if mode == .notifications { item.owner = Reminder.devicePerson }
                    if mode == .tasks, let owner = Reminder.Owner(rawValue: ownerFilter) { item.owner = owner }
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
    private func summary(_ tasks: [Reminder]) -> Text {
        if mode == .notifications {
            let paused = tasks.filter { !$0.enabled }.count
            return Text("\(tasks.count) scheduled") + Text(paused > 0 ? " · \(paused) paused" : "")
        }
        if completedScope {
            let delayed = tasks.filter { $0.isDelayed(at: now) }.count
            return Text("\(tasks.count - delayed) done today · \(delayed) delayed")
        }
        let overdue = tasks.filter { $0.isOverdue(at: now) }.count
        return Text("\(tasks.count) active") + (overdue > 0 ? Text(" · ") + Text("\(overdue) overdue").foregroundStyle(.red).bold() : Text(""))
    }
    /// Scheduled tasks grouped by when they're next due, so a long list is easy to scan.
    private func scheduledGroups(_ tasks: [Reminder]) -> [(String, [Reminder])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!
        let sorted = tasks.sorted(by: Reminder.dashboardOrderedBefore)
        let overdue = sorted.filter { $0.isOverdue(at: now) }
        let rest = sorted.filter { !$0.isOverdue(at: now) }
        let dueToday = rest.filter { $0.isDueToday(at: now) }
        let upcoming = rest.filter { !$0.isDueToday(at: now) }.sorted { $0.effectiveDate < $1.effectiveDate }
        return [
            ("Overdue", overdue),
            ("Today", dueToday),
            ("Tomorrow", upcoming.filter { calendar.isDate($0.effectiveDate, inSameDayAs: tomorrow) }),
            ("This week", upcoming.filter { $0.effectiveDate >= calendar.date(byAdding: .day, value: 1, to: tomorrow)! && $0.effectiveDate < nextWeek }),
            ("Later", upcoming.filter { $0.effectiveDate >= nextWeek || $0.effectiveDate < tomorrow })
        ]
    }
    private func board(_ title: String, icon: String, accent: Color, groups: [(String, [Reminder])], random: [Reminder]? = nil) -> some View {
        let count = groups.reduce(0) { $0 + $1.1.count }
        return VStack(alignment: .leading, spacing: 8) {
            HippoSectionHeader(title: title, icon: icon, count: count, accent: accent) {
                if let random {
                    Button("Random pick", systemImage: "dice") { randomPick = random.randomElement() }
                        .buttonStyle(.bordered).disabled(random.isEmpty)
                        .accessibilityLabel("Pick a random task from " + title)
                }
            }.padding(.bottom, 4)
            if count == 0 {
                HippoNotice(text: search.isEmpty ? "Nothing here right now." : "No matching tasks.", accent: accent)
            }
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { group in
                if !group.0.isEmpty {
                    HippoGroupLabel(group.0, color: group.0 == "Overdue" ? .red : group.0 == "Today" ? accent : .secondary)
                }
                HippoGrid(minimum: 300, spacing: 8) {
                    ForEach(group.1) { card($0, accent: accent, resting: group.0 == "Resting") }
                }
            }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HippoEmptyState(title: mode == .notifications ? "No notifications yet" : completedScope ? "Nothing done or delayed" : "All clear", icon: mode == .notifications ? "bell" : "checkmark.circle", message: mode == .notifications ? "Add a notification to schedule an alert. Tasks and reminders stay silent." : completedScope ? "Tasks completed today and delayed tasks appear here so you can bring them back." : search.isEmpty ? "Add a task or import your Apple Reminders." : "No tasks match your search.")
            if mode == .tasks && !store.reminders.contains(where: { !$0.isNotification }) {
                Button("Import Apple Reminders…", systemImage: "square.and.arrow.down") { importing = true }.padding(.bottom, 12)
            }
        }.padding(.horizontal, 16).padding(.vertical, 4).hippoCard()
    }
    @ViewBuilder private var deliveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Delivery", systemImage: "bell.badge").font(.headline)
            #if os(iOS)
            switch store.status {
            case .notDetermined:
                Button("Allow notifications") { Task { await store.requestPermission() } }.buttonStyle(.borderedProminent)
            case .authorized:
                Label("Notifications allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .provisional, .ephemeral:
                Text("Notifications are allowed quietly or temporarily. Review delivery settings for banners and sounds.").font(.callout)
                Link("Open notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
            case .denied:
                Text("Notifications are disabled for HouseHippo on this iPhone.").font(.callout)
                Link("Open notification settings", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
            @unknown default:
                Text("Review HouseHippo notification permissions in Settings.").font(.callout)
            }
            #endif
            if let coverage = store.coverage { Text("Open the app before \(coverage.formatted(date: .abbreviated, time: .shortened)) to refresh notification coverage.").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).hippoCard()
    }
    private func card(_ task: Reminder, accent: Color, resting: Bool = false) -> some View {
        let overdue = !completedScope && task.isOverdue(at: now)
        let delayed = task.isDelayed(at: now)
        let tint: Color = overdue ? .red : resting ? .secondary : accent
        return HStack(spacing: 0) {
            Group {
                if task.isNotification {
                    Button { Task { await store.toggle(task) } } label: {
                        Image(systemName: task.enabled ? "bell.fill" : "bell.slash").font(.title3)
                    }.accessibilityLabel(task.enabled ? "Pause notification" : "Resume notification")
                } else {
                    Button { Task {
                        if completedScope && delayed { await store.moveBackToToday(task) }
                        else if completedScope { await store.undoCompletion(task) }
                        else { await store.complete(task) }
                    } } label: {
                        Image(systemName: completedScope ? (delayed ? "arrow.uturn.backward.circle" : "checkmark.circle.fill") : "circle").font(.title2)
                    }.accessibilityLabel(completedScope ? (delayed ? "Move \(task.title) back to today" : "Undo completion of \(task.title)") : "Mark \(task.title) done")
                }
            }
            .buttonStyle(.plain).foregroundStyle(tint)
            .frame(width: 44).frame(maxHeight: .infinity).contentShape(Rectangle())
            Button { editing = task } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.headline).foregroundStyle(overdue ? .red : .primary).lineLimit(2)
                        Text(details(task)).font(.caption).foregroundStyle(overdue ? .red : .secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(task.owner.displayName).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.primary.opacity(0.06), in: Capsule())
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(.vertical, 8).padding(.trailing, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .hippoCard(border: overdue ? Color.red.opacity(0.4) : Color.primary.opacity(0.08))
        .opacity(resting ? 0.75 : 1)
        .contextMenu {
            if task.isNotification {
                Button(task.enabled ? "Pause notification" : "Resume notification") { Task { await store.toggle(task) } }
            }
            if delayed {
                Button("Move back to today", systemImage: "arrow.uturn.backward") { Task { await store.moveBackToToday(task) } }
            }
            if task.canMoveToTomorrow && !completedScope {
                Button("Move to tomorrow", systemImage: "calendar.badge.clock") { Task { await store.moveToTomorrow(task) } }
            }
            if !completedScope && task.nextRepeatDate() != nil {
                Button("Move to next repeat", systemImage: "calendar.badge.arrow.right") { Task { await store.moveToNextRepeat(task) } }
            }
            if task.isFlexibleTask && !task.completed {
                Button("Convert to Waiting For", systemImage: "clock") { Task { await store.convertToWaitingFor(task) } }
            }
            Button("Delete", role: .destructive) { Task { await store.delete(task) } }
        }
    }
    private func details(_ task: Reminder) -> String {
        var parts = [task.summary, task.list]
        if task.isNotification && !task.enabled { parts.append("Paused") }
        if let done = task.lastCompleted { parts.append("Last done " + done.formatted(date: .abbreviated, time: .omitted)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ReminderEditor: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State var reminder: Reminder
    private let original: Reminder
    @State private var saving = false
    @State private var lists: [EKCalendar] = []
    @State private var selectedListID = ""
    @State private var loadingLists = true
    @State private var listError: String?

    init(reminder: Reminder) {
        _reminder = State(initialValue: reminder)
        original = reminder
    }

    private func canSelect(_ list: EKCalendar) -> Bool {
        let config = AppleSyncService.shared.settings()
        return !reminder.syncsWithAppleReminders || !config.enabled || config.calendarIDs.contains(list.calendarIdentifier)
    }
    private var validList: Bool {
        reminder.isNotification || lists.contains { $0.calendarIdentifier == selectedListID && canSelect($0) }
    }
    private func loadLists() async {
        loadingLists = true
        listError = nil
        do {
            lists = try await store.reminderLists().filter(\.allowsContentModifications)
            if let linked = reminder.appleReminderCalendarID,
               lists.contains(where: { $0.calendarIdentifier == linked && AppleRemindersAdapter.listName($0.title) == reminder.list }) {
                selectedListID = linked
            } else {
                let matches = lists.filter { AppleRemindersAdapter.listName($0.title) == reminder.list && canSelect($0) }
                selectedListID = matches.count == 1 ? matches[0].calendarIdentifier : ""
            }
        } catch { listError = error.localizedDescription }
        loadingLists = false
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(reminder.isNotification ? "Notification" : "Task") {
                    HippoField("Title", text: $reminder.title, prompt: "What needs doing?")
                    if reminder.isNotification {
                        HippoField("Notification message", text: $reminder.message)
                        Picker("For", selection: $reminder.owner) { ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        Text("Alerts go to the assigned person's devices. Shared alerts go to both people. Choose who uses this device on the Dashboard.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("List", selection: $selectedListID) {
                            Text("Choose a list…").tag("")
                            ForEach(lists, id: \.calendarIdentifier) { list in
                                Text(list.title + " · " + list.source.title + (canSelect(list) ? "" : " (sync off)"))
                                    .tag(list.calendarIdentifier)
                                    .disabled(!canSelect(list))
                            }
                        }
                        .disabled(loadingLists)
                        .onChange(of: selectedListID) { _, id in
                            guard let list = lists.first(where: { $0.calendarIdentifier == id }) else { return }
                            reminder.list = AppleRemindersAdapter.listName(list.title)
                            reminder.appleReminderCalendarID = id
                        }
                        if loadingLists { ProgressView("Loading Reminders lists…") }
                        if let listError {
                            Text(listError).foregroundStyle(.red)
                            Button("Retry loading lists") { Task { await loadLists() } }
                        } else if !loadingLists && lists.isEmpty {
                            Text("Create a writable list in Apple Reminders, then reload it here.")
                            Button("Reload lists") { Task { await loadLists() } }
                        } else if !loadingLists && !validList {
                            Text("Choose an available list. Enable it in Apple Sync settings if needed.").font(.caption)
                        }
                        Picker("For", selection: $reminder.owner) { ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    }
                }
                if reminder.isNotification {
                    Section {
                        HippoField("Shortcut name (optional)", text: Binding(get: { reminder.shortcutName ?? "" }, set: { reminder.shortcutName = $0 }), prompt: "Name from the Shortcuts app")
                            .autocorrectionDisabled()
                        #if os(iOS)
                        if let url = reminder.shortcutURL {
                            Link("Test shortcut", destination: url)
                        }
                        #endif
                        DisclosureGroup("Set up an app shortcut") {
                            Text("1. Open Apple's Shortcuts app and create a shortcut.\n2. Add the Open App action and choose Fertility Friend (or another app).\n3. Name it, for example, Open Fertility Friend.\n4. Enter that exact shortcut name above and test it.")
                            Text("Create the shortcut on each iPhone that receives this notification. If you rename it, update the name here too.")
                        }
                    } header: {
                        Text("When tapped")
                    } footer: {
                        Text("Leave blank to open HouseHippo. Otherwise, tapping the notification runs your shortcut through Shortcuts. You may need to unlock your iPhone. A missing shortcut is reported by Shortcuts.")
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
                if reminder.isFlexibleTask && !reminder.completed && store.reminders.contains(where: { $0.id == reminder.id }) {
                    Section {
                        Button("Convert to Waiting For", systemImage: "clock") {
                            saving = true
                            Task {
                                if await store.convertToWaitingFor(reminder) { dismiss() }
                                saving = false
                            }
                        }.disabled(saving || reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Moves this task to Waiting For, with its notes as the first update.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TaskNoteSection(reminder: $reminder)
            }.hippoForm()
            .navigationTitle(reminder.isNotification ? "Notification details" : "Task details")
            .onAppear { if reminder.isUnscheduled { reminder.frequency = .anytime } }
            .task { if !reminder.isNotification { await loadLists() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        reminder.title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let shortcutName = reminder.shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        reminder.shortcutName = shortcutName.isEmpty ? nil : shortcutName
                        // Save a local copy: changing the editor's date here would rerun its onChange handler.
                        let prepared = reminder.preparedForEditorSave(original: original)
                        Task { await store.save(prepared); dismiss() } }.disabled(saving || !validList || reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// A private data type keeps editable text fields from consuming a day index as text on iOS.
private struct MealDayDrag: Codable, Transferable {
    let day: Int
    let week: Date

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .houseHippoMealDay)
    }
}

private extension UTType {
    static let houseHippoMealDay = UTType(exportedAs: "com.househippo.meal-day", conformingTo: .data)
}

struct MealsView: View {
    var body: some View { NavigationStack { MealsPage() } }
}

private struct MealsPage: View {
    @ObservedObject private var cloud = CloudStore.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var dinners = Array(repeating: "", count: 7)
    @State private var targetedDay: Int?
    @State private var week = MealWeek.start(containing: Date())
    @State private var now = Date()
    private var currentDinners: [String] {
        (0..<7).map { day in
            let date = Calendar.current.date(byAdding: .day, value: day, to: week)!
            return (try? cloud.read(MealWeek.storageKey(for: date))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    /// Position of today in the shown week, so the iPhone strip starts at tonight's dinner.
    private var todayIndex: Int? {
        (0..<7).first { Calendar.current.isDate(Calendar.current.date(byAdding: .day, value: $0, to: week)!, inSameDayAs: Date()) }
    }
    private var weekLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: week)!
        return week.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day())
    }
    var body: some View {
        let planned = dinners.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let groceries = ((try? cloud.groceries()) ?? []).filter { !$0.checked }.count
        return HippoCanvas {
            HippoPageHeader(title: "Meals", summary: Text("\(planned) of 7 dinners planned · \(groceries) " + (groceries == 1 ? "grocery" : "groceries") + " to get")) {
                weekControls
            }
            VStack(alignment: .leading, spacing: 12) {
                HippoSectionHeader(title: "Dinners", icon: "fork.knife") {
                    if !compact { Text("Drag a day onto another to swap").font(.caption).foregroundStyle(.secondary) }
                }
                if compact {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(0..<7, id: \.self) { dayCard($0).frame(width: 132).id($0) } }
                                .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                        .onAppear { if let today = todayIndex { reader.scrollTo(today, anchor: .leading) } }
                        .onChange(of: week) { _, _ in reader.scrollTo(todayIndex ?? 0, anchor: .leading) }
                    }
                } else {
                    HippoGrid(minimum: 132, spacing: 10) { ForEach(0..<7, id: \.self) { dayCard($0) } }
                }
            }
            GroceryView()
        }
        .hippoCanvasPage("Meals")
        .onAppear {
            now = Date()
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
    private var weekControls: some View {
        HStack(spacing: 8) {
            Button { moveWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).accessibilityLabel("Previous week")
            Text(weekLabel).font(.subheadline.weight(.semibold)).monospacedDigit().frame(minWidth: 110)
            Button { moveWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).accessibilityLabel("Next week")
            if week != MealWeek.start(containing: Date()) {
                Button("This week") { week = MealWeek.start(containing: Date()); dinners = currentDinners }.buttonStyle(.bordered)
            }
        }
    }
    private func dayCard(_ day: Int) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: day, to: week)!
        let isToday = Calendar.current.isDate(date, inSameDayAs: now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.caption2.weight(.bold)).tracking(0.6)
                        Text(date.formatted(.dateTime.day())).font(.system(.title3, design: .rounded).bold())
                    }.fixedSize(horizontal: true, vertical: false)
                    // Reserve the same second line in every card so dinner fields stay aligned.
                    Text("Tonight").font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(isToday ? 1 : 0).accessibilityHidden(!isToday)
                }
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                    .accessibilityLabel("Drag to swap dinner")
                    .help("Drag to another day to swap dinners")
                    .onDrag {
                        let provider = NSItemProvider()
                        let payload = MealDayDrag(day: day, week: week)
                        provider.registerDataRepresentation(forTypeIdentifier: UTType.houseHippoMealDay.identifier, visibility: .all) { completion in
                            do { completion(try JSONEncoder().encode(payload), nil) }
                            catch { completion(nil, error) }
                            return nil
                        }
                        return provider
                    }
            }.foregroundStyle(isToday ? Color.teal : Color.secondary)
            TextField("Add dinner…", text: $dinners[day], axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .accessibilityLabel("Dinner for " + date.formatted(date: .complete, time: .omitted))
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(targetedDay == day ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
        .hippoCard(border: isToday ? .teal : Color.primary.opacity(0.08), lineWidth: isToday ? 2 : 1)
        .onDrop(of: [UTType.houseHippoMealDay], isTargeted: Binding(
            get: { targetedDay == day },
            set: { targeted in
                if targeted { targetedDay = day }
                else if targetedDay == day { targetedDay = nil }
            }
        )) { providers in
            guard let provider = providers.first else { return false }
            let destinationWeek = week
            provider.loadDataRepresentation(forTypeIdentifier: UTType.houseHippoMealDay.identifier) { data, _ in
                guard let data, let value = try? JSONDecoder().decode(MealDayDrag.self, from: data) else { return }
                DispatchQueue.main.async {
                    guard week == destinationWeek else { return }
                    _ = swapDinner(value, onto: day)
                }
            }
            return true
        }
    }
    private func moveWeek(_ offset: Int) {
        week = Calendar.current.date(byAdding: .weekOfYear, value: offset, to: week)!
        dinners = currentDinners
    }
    @discardableResult private func swapDinner(_ value: MealDayDrag, onto day: Int) -> Bool {
        guard value.week == week, (0..<7).contains(value.day),
              (0..<7).contains(day), value.day != day else { return false }
        dinners.swapAt(value.day, day)
        return true
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
            }.hippoForm()
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
