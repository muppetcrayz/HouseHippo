import Foundation

extension Reminder {
    var canMoveToTomorrow: Bool { !isNotification && !completed && deletedAt == nil }
    mutating func moveToTomorrow(at now: Date = Date(), calendar: Calendar = .current) {
        guard canMoveToTomorrow,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        deferredUntil = isAllDay || isFlexibleTask ? tomorrow : calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: tomorrow)
    }

    func isDelayed(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard canMoveToTomorrow, let deferredUntil else { return false }
        return calendar.startOfDay(for: deferredUntil) > calendar.startOfDay(for: now)
    }
    mutating func moveBackToToday(at now: Date = Date(), calendar: Calendar = .current) {
        guard isDelayed(at: now, calendar: calendar) else { return }
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        let today = calendar.startOfDay(for: now)
        deferredUntil = isAllDay || isFlexibleTask ? today : calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: today)
    }

    func wasCompletedToday(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard deletedAt == nil, let lastCompleted else { return false }
        return calendar.isDate(lastCompleted, inSameDayAs: now)
    }
    var canRetireCompletion: Bool { completed && !wasCompletedToday() }
    mutating func undoTodayCompletion(at now: Date = Date(), calendar: Calendar = .current) {
        guard wasCompletedToday(at: now, calendar: calendar), let completion = lastCompleted else { return }
        if let previous = dateBeforeCompletion { date = previous }
        else if !completed && frequency != .flexible {
            // Older/cloud completions have no saved pre-completion date.
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: completion) ?? completion
        }
        history.removeAll { $0 == completion }
        lastCompleted = history.max()
        dateBeforeCompletion = nil
        deferredUntil = deferredBeforeCompletion
        deferredBeforeCompletion = nil
        completed = false
    }

    mutating func markCompleted(at now: Date = Date(), calendar: Calendar = .current) {
        guard !completed else { return }
        if frequency == .flexible, let lastCompleted, calendar.isDate(lastCompleted, equalTo: now, toGranularity: .month) { return }
        dateBeforeCompletion = date
        deferredBeforeCompletion = deferredUntil
        let nextDue = deferredUntil ?? date
        deferredUntil = nil
        lastCompleted = now
        history.append(now)
        if frequency == .once || frequency == .anytime { completed = true }
        else if frequency != .flexible {
            recurrenceAnchor = recurrenceAnchor ?? date
            let reference = isAllDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(now, nextDue)))!.addingTimeInterval(-1) : max(now, nextDue)
            if let next = nextScheduledOccurrence(after: reference, calendar: calendar) { date = next }
            else { completed = true }
        }
    }

    struct ImportedRule {
        let frequency: String
        let interval: Int
        let days: [Int]?
        let monthDay: Int?
        let lastDay: Bool
        let weekStart: Int
        let until: Date?

        static func parse(_ original: String) throws -> ImportedRule {
            func invalid(_ reason: String) -> NSError { NSError(domain: "HouseHippo.Recurrence", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
            guard original.components(separatedBy: "RRULE").count == 2, let range = original.range(of: "RRULE") else { throw invalid("Multiple or missing recurrence rules") }
            let text = original[range.upperBound...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
            var fields: [String: String] = [:]
            for part in text.split(separator: ";", omittingEmptySubsequences: false) {
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2, fields[String(pieces[0])] == nil, !pieces[1].isEmpty else { throw invalid("Malformed recurrence rule") }
                fields[String(pieces[0])] = String(pieces[1])
            }
            let allowed: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYSETPOS", "WKST", "UNTIL"]
            let unknown = Set(fields.keys).subtracting(allowed)
            guard unknown.isEmpty else { throw invalid("Unsupported rule fields: " + unknown.sorted().joined(separator: ", ")) }
            guard let frequency = fields["FREQ"], ["DAILY", "WEEKLY", "MONTHLY"].contains(frequency) else { throw invalid("Unsupported recurrence frequency") }
            guard let interval = Int(fields["INTERVAL"] ?? "1"), (1...365).contains(interval) else { throw invalid("Unsupported repeat interval") }
            let weekdayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
            let start: Int
            if let code = fields["WKST"] { guard let day = weekdayCodes[code] else { throw invalid("Unknown week start") }; start = day }
            else { start = 2 } // RFC 5545 default: Monday.
            var until: Date?
            if let raw = fields["UNTIL"] {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; formatter.isLenient = false
                guard raw.count == 16, let parsed = formatter.date(from: raw), formatter.string(from: parsed) == raw else { throw invalid("Unsupported recurrence end date") }
                until = parsed
            }
            var days: [Int]?
            if let raw = fields["BYDAY"] {
                let codes = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                let values = codes.compactMap { weekdayCodes[$0] }
                guard frequency == "WEEKLY", values.count == codes.count else { throw invalid("Unsupported weekday pattern") }
                days = Set(values).sorted()
            }
            var monthDay: Int?
            var lastDay = false
            if let raw = fields["BYMONTHDAY"] {
                guard frequency == "MONTHLY" else { throw invalid("Month-day filter on a non-monthly rule") }
                let rawDays = raw.split(separator: ",", omittingEmptySubsequences: false)
                let values = rawDays.compactMap { Int($0) }
                guard values.count == rawDays.count else { throw invalid("Invalid month-day filter") }
                if values == [-1] && fields["BYSETPOS"] == nil { lastDay = true }
                else if Set(values) == Set([28, 29, 30, 31]) && fields["BYSETPOS"] == "-1" { lastDay = true }
                else if values.count == 1, let value = values.first, (1...31).contains(value), fields["BYSETPOS"] == nil { monthDay = value }
                else { throw invalid("Unsupported monthly pattern") }
            } else if fields["BYSETPOS"] != nil { throw invalid("Position filter without a supported monthly pattern") }
            return ImportedRule(frequency: frequency, interval: interval, days: days, monthDay: monthDay, lastDay: lastDay, weekStart: start, until: until)
        }
    }

    mutating func matchImportedRecurrence(respectFlexibleLists: Bool = true) {
        let marker = "\n\nImported repeating reminder."
        let generatedStart = notes.range(of: marker)
        let archivedStart = generatedStart.flatMap { notes.range(of: "Original rule: ", range: $0.upperBound..<notes.endIndex) }
        let archivedEnd = archivedStart.map { start in notes[start.upperBound...].firstIndex(where: { $0.isNewline }) ?? notes.endIndex }
        let raw: String
        if let originalRecurrenceRule { raw = originalRecurrenceRule }
        else if let start = archivedStart, let end = archivedEnd { raw = String(notes[start.upperBound..<end]) }
        else { return }
        originalRecurrenceRule = raw
        if let start = generatedStart, let end = archivedEnd {
            // Remove only our generated rule line; preserve notes added before OR after it.
            notes.removeSubrange(start.lowerBound..<end)
        }
        guard recurrenceImportVersion != 1 else { return }
        recurrenceImportVersion = 1
        // Preserve schedules the user already configured, and the explicit meaning of flexible lists.
        guard frequency == .once || frequency == .anytime else { return }
        if respectFlexibleLists && (listRole == .flexiblePersonal || listRole == .flexibleHousehold) { return }
        do {
            let rule = try ImportedRule.parse(raw)
            guard hasDueDate != false, date > Date.distantPast.addingTimeInterval(86400) else {
                throw NSError(domain: "HouseHippo.Recurrence", code: 2, userInfo: [NSLocalizedDescriptionKey: "The original rule has no dated starting occurrence"])
            }
            recurrenceAnchor = date
            recurrenceUntil = rule.until
            hasDueDate = true
            switch rule.frequency {
            case "DAILY":
                frequency = rule.interval == 1 ? .daily : .custom
                interval = rule.interval; unit = .days
            case "WEEKLY":
                frequency = .weekly
                selectedWeekdays = rule.days ?? [Calendar.current.component(.weekday, from: date)]
                weeklyEvery = rule.interval; recurrenceWeekStart = rule.weekStart
            default:
                frequency = .monthly
                monthlyEvery = rule.interval; monthlyOnLastDay = rule.lastDay
                monthlyDay = rule.monthDay ?? Calendar.current.component(.day, from: date)
            }
            recurrenceReviewReason = nil
        } catch { recurrenceReviewReason = error.localizedDescription }
    }

    var weeklyStep: Int { max(1, weeklyEvery ?? 1) }
    var monthlyStep: Int { max(1, monthlyEvery ?? 1) }
    func isAllowedWeek(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard weeklyStep > 1 else { return true }
        var weekCalendar = calendar
        weekCalendar.firstWeekday = recurrenceWeekStart ?? 2
        guard let first = weekCalendar.dateInterval(of: .weekOfYear, for: recurrenceAnchor ?? self.date)?.start,
              let candidate = weekCalendar.dateInterval(of: .weekOfYear, for: date)?.start else { return false }
        let weeks = (weekCalendar.dateComponents([.day], from: first, to: candidate).day ?? -7) / 7
        return weeks >= 0 && weeks % weeklyStep == 0
    }
    func withinRecurrenceEnd(_ date: Date) -> Bool { recurrenceUntil.map { date <= $0 } ?? true }
    func nextMonthlyOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        let anchor = recurrenceAnchor ?? date
        let firstMonth = calendar.dateInterval(of: .month, for: anchor)!.start
        let currentMonth = calendar.dateInterval(of: .month, for: reference)!.start
        let elapsed = max(0, calendar.dateComponents([.month], from: firstMonth, to: currentMonth).month ?? 0)
        let time = calendar.dateComponents([.hour, .minute], from: anchor)
        for offset in elapsed..<(elapsed + 24 * monthlyStep + 1) where offset % monthlyStep == 0 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: firstMonth), let range = calendar.range(of: .day, in: .month, for: month) else { continue }
            let day = monthlyOnLastDay == true ? range.count : (monthlyDay ?? calendar.component(.day, from: anchor))
            guard range.contains(day) else { continue } // Fixed day 31 skips short months; it never drifts to day 28.
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = day; components.hour = isAllDay ? 0 : time.hour; components.minute = isAllDay ? 0 : time.minute
            if let next = calendar.date(from: components), next > reference, next >= anchor { return withinRecurrenceEnd(next) ? next : nil }
        }
        return nil
    }
    func nextIntervalOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        let anchor = recurrenceAnchor ?? date
        let component: Calendar.Component
        if frequency == .daily { component = .day }
        else { component = switch unit { case .hours: .hour; case .days: .day; case .weeks: .weekOfYear; case .months: .month } }
        let step = frequency == .daily ? 1 : max(1, interval)
        var index = max(0, (calendar.dateComponents([component], from: anchor, to: reference).value(for: component) ?? 0) / step - 1)
        for _ in 0..<8 {
            guard let next = calendar.date(byAdding: component, value: index * step, to: anchor) else { return nil }
            if next > reference { return withinRecurrenceEnd(next) ? next : nil }
            index += 1
        }
        return nil
    }
    func nextScheduledOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        switch frequency {
        case .weekly: return nextWeeklyOccurrence(after: reference, calendar: calendar)
        case .monthly: return nextMonthlyOccurrence(after: reference, calendar: calendar)
        case .daily, .custom: return nextIntervalOccurrence(after: reference, calendar: calendar)
        default: return nil
        }
    }
    var usesRollingNotifications: Bool {
        frequency == .custom || frequency == .flexible || recurrenceUntil != nil ||
        (frequency == .weekly && weeklyStep > 1) ||
        (frequency == .monthly && (monthlyOnLastDay == true || monthlyStep > 1))
    }
    var summary: String {
        if let recurrenceReviewReason { return "Repeat needs review: " + recurrenceReviewReason }
        let base = (deferredUntil.map { "Next due " + $0.formatted(date: .abbreviated, time: isAllDay || isFlexibleTask ? .omitted : .shortened) + " · " } ?? "") + scheduleSummary
        return recurrenceUntil.map { base + " · until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? base
    }
}
