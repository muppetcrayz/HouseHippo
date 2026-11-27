import XCTest
import EventKit

final class GroceryModelTests: XCTestCase {
    func testCategorySuggestionsAndPhrasePrecedence() {
        let cases: [(String, GroceryCategory)] = [
            ("2 lb APPLES", .produce), ("bell-peppers", .produce),
            ("peanut butter", .pantry), ("chicken broth", .pantry),
            ("frozen chicken", .frozen), ("ice cream", .frozen),
            ("dog food", .household), ("dish soap", .household),
            ("milk", .dairy), ("salmon", .meat), ("bagels", .bakery),
            ("coffee", .drinks), ("mystery item", .other), ("", .other),
            ("hamster toy", .other), ("eggplant", .produce)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(GroceryCategory.suggest(for: name), expected, name)
        }
    }

    func testLegacyChecklistsPreserveNamesAndCheckedState() {
        for line in ["- [x] Apples", "* [X] Apples", "• ☑ Apples", "✅ Apples"] {
            let parsed = GroceryItem.legacyLine(line)
            XCTAssertEqual(parsed?.name, "Apples", line)
            XCTAssertEqual(parsed?.checked, true, line)
        }
        for line in ["- [ ] Apples", "☐ Apples", "  Apples  "] {
            XCTAssertEqual(GroceryItem.legacyLine(line)?.name, "Apples")
            XCTAssertEqual(GroceryItem.legacyLine(line)?.checked, false)
        }
        for line in ["", " \n ", "- [ ]", "☑"] {
            XCTAssertNil(GroceryItem.legacyLine(line), line)
        }
    }

    func testCategoryOverrideSurvivesEncodingAndCanReturnToAutomatic() throws {
        var item = GroceryItem(name: "milk", checked: true, categoryOverride: .other)
        XCTAssertEqual(item.category, .other)
        let decoded = try JSONDecoder().decode(GroceryItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        item.categoryOverride = nil
        XCTAssertEqual(item.category, .dairy)
    }

    func testLegacyGroceryWithoutOptionalFieldsDecodes() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"apples\",\"checked\":false}".utf8)
        let item = try JSONDecoder().decode(GroceryItem.self, from: data)
        XCTAssertEqual(item.id, id)
        XCTAssertNil(item.deletedAt)
        XCTAssertEqual(item.category, .produce)
    }
}

final class CalendarModelTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testMealWeekStartsOnSaturdayAcrossYearBoundary() {
        let cal = calendar()
        for day in 1...7 {
            let input = date(2030, 1, day, calendar: cal)
            let start = MealWeek.start(containing: input, calendar: cal)
            XCTAssertEqual(cal.component(.weekday, from: start), 7)
            XCTAssertLessThanOrEqual(start, input)
            XCTAssertLessThan(cal.dateComponents([.day], from: start, to: input).day!, 7)
        }
        XCTAssertEqual(MealWeek.storageKey(for: MealWeek.start(containing: date(2030, 1, 1, calendar: cal), calendar: cal), calendar: cal), "househippo.dinnerDate.2029-12-29")
    }

    func testMealWeekAndKeysAcrossDaylightSavingTransitions() {
        for zone in ["America/New_York", "Europe/London", "Pacific/Auckland", "UTC"] {
            let cal = calendar(zone)
            for (month, day) in [(3, 10), (11, 3)] {
                let input = date(2030, month, day, calendar: cal)
                let start = MealWeek.start(containing: input, calendar: cal)
                XCTAssertEqual(cal.component(.hour, from: start), 0)
                XCTAssertEqual(cal.component(.weekday, from: start), 7)
                let keys = (0..<7).map { MealWeek.storageKey(for: cal.date(byAdding: .day, value: $0, to: start)!, calendar: cal) }
                XCTAssertEqual(Set(keys).count, 7)
            }
        }
    }

    func testLastTimeStoresCalendarDayAcrossTimeZones() throws {
        let ny = calendar(), tokyo = calendar("Asia/Tokyo")
        let entry = LastTimeEntry(title: "Filter", date: date(2030, 5, 4, calendar: ny), calendar: ny)
        let restored = try JSONDecoder().decode(LastTimeEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(tokyo.dateComponents([.year, .month, .day], from: restored.date(calendar: tokyo)), DateComponents(year: 2030, month: 5, day: 4))
        XCTAssertEqual(entry.assignedTo, .shared)
        XCTAssertTrue(entry.isVisible(to: .husband))
    }

    func testLastTimeElapsedBoundariesAndAssignment() {
        let cal = calendar()
        var entry = LastTimeEntry(title: "Filter", date: date(2030, 5, 4, calendar: cal), calendar: cal)
        for (day, expected) in [(3, "In the future"), (4, "Today"), (5, "Yesterday"), (6, "2 days ago"), (11, "About a week ago")] {
            XCTAssertEqual(entry.elapsed(since: date(2030, 5, day, calendar: cal), calendar: cal), expected)
        }
        entry.owner = .me
        XCTAssertTrue(entry.isVisible(to: .me))
        XCTAssertFalse(entry.isVisible(to: .husband))
    }
}

final class TaskAndSyncTests: XCTestCase {
    func testEveryThreeWaySyncCombination() {
        let a = Data("a".utf8), b = Data("b".utf8)
        let values: [Data?] = [nil, a, b]
        for base in values {
            for local in values {
                for remote in values {
                    let expected: AppleSyncPolicy.Action
                    if local == remote { expected = .acknowledge }
                    else if base == nil { expected = .conflict }
                    else if local == base { expected = .pull }
                    else if remote == base { expected = .push }
                    else { expected = .conflict }
                    XCTAssertEqual(AppleSyncPolicy.action(base: base, local: local, remote: remote), expected,
                                   "base=\(String(describing: base)), local=\(String(describing: local)), remote=\(String(describing: remote))")
                }
            }
        }
    }

    func testWaitingUpdateCreatesSilentFlexibleTaskForEachOwner() {
        let update = WaitingUpdate(recordID: UUID(), text: "Call the plumber")
        for owner in Reminder.Owner.allCases {
            let task = update.flexibleTask(recordTitle: "Repair", owner: owner)
            XCTAssertEqual(task.title, update.text)
            XCTAssertEqual(task.owner, owner)
            XCTAssertTrue(task.isFlexibleTask)
            XCTAssertEqual(task.hasDueDate, false)
            XCTAssertFalse(task.shouldNotify)
            XCTAssertTrue(task.taskNote?.contains("Waiting For: Repair") == true)
        }
    }

    func testNotificationEligibilityByOwnerAndState() {
        var task = Reminder(title: "Alert", message: "", date: Date(), frequency: .daily)
        task.kind = .notification
        for owner in Reminder.Owner.allCases {
            task.owner = owner
            for person in [Reminder.Owner.me, .husband] {
                XCTAssertEqual(task.shouldNotify(on: person), owner == .shared || owner == person)
            }
        }
        task.enabled = false
        XCTAssertFalse(task.shouldNotify)
        task.enabled = true; task.completed = true
        XCTAssertFalse(task.shouldNotify)
        task.completed = false; task.kind = .task
        XCTAssertFalse(task.shouldNotify)
    }

    func testSyncedNotesEscapeMarkupAndKeepBodyIndependentOfTitle() {
        let value = SyncedNoteValue(title: "<Home> & \"garden\"", body: "One\n<script>two</script>")
        XCTAssertFalse(value.html.contains("<script>"))
        XCTAssertTrue(value.html.contains("&lt;Home&gt;"))
        XCTAssertTrue(value.html.contains("One<br>"))
        XCTAssertEqual(SyncedNoteValue.removingTitle("Home\nBody", title: "Home"), "Body")
        XCTAssertEqual(SyncedNoteValue.removingTitle("Body", title: "Home"), "Body")
    }

    func testInventoryCSVRejectsMalformedRowsAndKeepsLeadingZeros() throws {
        let csv = try InventoryCSV("Title,Catalog\r\n\"Record, One\",0012\r\n")
        XCTAssertEqual(csv.rows, [["Record, One", "0012"]])
        for input in ["Name,name\nA,B", "Name,Notes\nA,B,C", "Name,Notes\nA,\"unclosed"] {
            XCTAssertThrowsError(try InventoryCSV(input), input)
        }
    }

    func testCurrencyParsingUsesExactCentsAndRejectsAmbiguousValues() {
        for (text, cents) in [("0.01", 1), ("12.34", 1234), ("-12.34", -1234), (" +2.5 ", 250)] {
            XCTAssertEqual(MoneyEntry.amount(text), cents)
        }
        for text in ["1.001", "1,000", "$2", "NaN", "", "1000000001"] {
            XCTAssertNil(MoneyEntry.amount(text), text)
        }
    }
}

final class RecurrenceTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/New_York")!
        return result
    }
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testFixedMonthlyDaySkipsShortMonthsWhileLastDayFollowsMonthEnd() {
        var task = Reminder(title: "Month end", message: "", date: at(2030, 1, 31), frequency: .monthly)
        task.allDay = true
        XCTAssertEqual(task.nextScheduledOccurrence(after: at(2030, 1, 31), calendar: calendar), at(2030, 3, 31))
        task.monthlyOnLastDay = true
        XCTAssertEqual(task.nextScheduledOccurrence(after: at(2030, 1, 31), calendar: calendar), at(2030, 2, 28))
        XCTAssertEqual(task.nextScheduledOccurrence(after: at(2032, 1, 31), calendar: calendar), at(2032, 2, 29))
    }

    func testDailyRecurrenceKeepsLocalClockAcrossDST() {
        let task = Reminder(title: "Daily", message: "", date: at(2030, 3, 9, 9), frequency: .daily)
        let next = task.nextScheduledOccurrence(after: at(2030, 3, 9, 10), calendar: calendar)
        XCTAssertEqual(next, at(2030, 3, 10, 9))
        XCTAssertEqual(next?.timeIntervalSince(task.date), 23 * 3600)
    }

    func testWeeklySkippingDoesNotCompleteTaskAndHonorsRecurrenceEnd() {
        var task = Reminder(title: "Weekly", message: "", date: at(2030, 11, 4), frequency: .weekly)
        task.allDay = true; task.selectedWeekdays = [2]
        task.moveToNextRepeat(at: at(2030, 11, 4), calendar: calendar)
        XCTAssertEqual(task.deferredUntil, at(2030, 11, 11))
        XCTAssertEqual(task.date, at(2030, 11, 4))
        XCTAssertFalse(task.completed)
        XCTAssertTrue(task.history.isEmpty)
        task.recurrenceUntil = at(2030, 11, 11)
        XCTAssertNil(task.nextRepeatDate(at: at(2030, 11, 4), calendar: calendar))
    }

    func testCompletionAndUndoRestoreOriginalDateAndDeferral() {
        var task = Reminder(title: "Daily", message: "", date: at(2030, 11, 4), frequency: .daily)
        task.allDay = true
        task.moveToTomorrow(at: at(2030, 11, 4, 12), calendar: calendar)
        let deferred = task.deferredUntil
        let completion = at(2030, 11, 5, 12)
        task.markCompleted(at: completion, calendar: calendar)
        XCTAssertEqual(task.history, [completion])
        XCTAssertNil(task.deferredUntil)
        task.undoTodayCompletion(at: completion, calendar: calendar)
        XCTAssertEqual(task.date, at(2030, 11, 4))
        XCTAssertEqual(task.deferredUntil, deferred)
        XCTAssertNil(task.lastCompleted)
        XCTAssertTrue(task.history.isEmpty)
        XCTAssertFalse(task.completed)
    }

    func testOneOffCompletionIsIdempotent() {
        var task = Reminder(title: "Once", message: "", date: at(2030, 11, 4), frequency: .once)
        task.markCompleted(at: at(2030, 11, 4, 12), calendar: calendar)
        task.markCompleted(at: at(2030, 11, 4, 13), calendar: calendar)
        XCTAssertTrue(task.completed)
        XCTAssertEqual(task.history.count, 1)
    }

    func testImportedUnsupportedRuleRequiresReviewRatherThanApproximation() {
        var task = Reminder(title: "Imported", message: "", date: at(2030, 11, 4), frequency: .once)
        task.originalRecurrenceRule = "RRULE FREQ=WEEKLY;BYDAY=1MO"
        task.matchImportedRecurrence()
        XCTAssertNotNil(task.recurrenceReviewReason)
        XCTAssertEqual(task.originalRecurrenceRule, "RRULE FREQ=WEEKLY;BYDAY=1MO")
        XCTAssertEqual(task.frequency, .once)
    }

    func testEditorKeepsDeferralForTitleEditAndClearsItForDateEdit() {
        var original = Reminder(title: "Once", message: "", date: at(2030, 11, 4), frequency: .once)
        original.allDay = true
        original.moveToTomorrow(at: at(2030, 11, 4), calendar: calendar)
        var edited = original; edited.title = "Renamed"
        XCTAssertEqual(edited.preparedForEditorSave(original: original, calendar: calendar).deferredUntil, original.deferredUntil)
        edited.date = at(2030, 12, 4)
        let saved = edited.preparedForEditorSave(original: original, calendar: calendar)
        XCTAssertNil(saved.deferredUntil)
        XCTAssertEqual(saved.date, at(2030, 12, 4))
    }
}

@MainActor private final class FakeDashboardCalendarReader: DashboardCalendarReading {
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    var available: [DashboardCalendarStore.CalendarChoice] = [.init(id: "apple", label: "Personal · iCloud"), .init(id: "google", label: "Work · Google")]
    var events: [DashboardCalendarStore.Item] = []
    var queries: [(DateInterval, Set<String>)] = []
    var accessRequests = 0
    var resets = 0
    var grant = true
    var failure: Error?
    func requestAccess() async throws -> Bool {
        accessRequests += 1
        if let failure { throw failure }
        authorizationStatus = grant ? .fullAccess : .denied
        return grant
    }
    func reset() { resets += 1 }
    func calendars() -> [DashboardCalendarStore.CalendarChoice] { available }
    func items(in day: DateInterval, calendarIDs: Set<String>) -> [DashboardCalendarStore.Item] {
        queries.append((day, calendarIDs)); return events
    }
}

@MainActor final class DashboardCalendarTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var reader: FakeDashboardCalendarReader!
    private var store: DashboardCalendarStore!
    override func setUp() async throws {
        suite = "HouseHippo.CalendarTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        reader = FakeDashboardCalendarReader()
        store = DashboardCalendarStore(defaults: defaults, reader: reader)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        store = nil; reader = nil; defaults = nil
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func item(_ id: String, _ start: String, _ end: String, calendarID: String = "apple", allDay: Bool = false, canceled: Bool = false) -> DashboardCalendarStore.Item {
        .init(id: id, calendarID: calendarID, title: id, start: date(start), end: date(end), allDay: allDay, canceled: canceled)
    }
    func testUnconfiguredAndMissingCalendarsNeverQueryAllCalendars() {
        store.refresh()
        XCTAssertTrue(reader.queries.isEmpty)
        store.sageID = "missing"
        store.danID = "also-missing"
        XCTAssertTrue(reader.queries.isEmpty)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.sageID, "missing")
    }
    func testOnlySelectedCalendarsAreRequestedAndReturned() {
        store.sageID = "apple"; store.danID = "google"
        reader.events = [item("apple event", "2026-11-27T15:00:00Z", "2026-11-27T16:00:00Z"),
                         item("google event", "2026-11-27T16:00:00Z", "2026-11-27T17:00:00Z", calendarID: "google"),
                         item("private event", "2026-11-27T16:00:00Z", "2026-11-27T17:00:00Z", calendarID: "private")]
        store.refresh(at: date("2026-11-27T17:00:00Z"), calendar: calendar)
        XCTAssertEqual(reader.queries.last?.1, Set(["apple", "google"]))
        XCTAssertEqual(store.items.map(\.id), ["apple event", "google event"])
        reader.available.removeAll { $0.id == "google" }
        store.refresh()
        XCTAssertEqual(reader.queries.last?.1, Set(["apple"]))
        XCTAssertEqual(store.danID, "google")
    }
    func testDayBoundariesOvernightAllDayCanceledAndOrdering() {
        store.sageID = "apple"
        reader.events = [
            item("later", "2026-11-27T20:00:00Z", "2026-11-27T21:00:00Z"),
            item("ends at midnight", "2026-11-27T04:00:00Z", "2026-11-27T05:00:00Z"),
            item("overnight", "2026-11-27T04:00:00Z", "2026-11-27T06:00:00Z"),
            item("tomorrow", "2026-11-28T05:00:00Z", "2026-11-28T06:00:00Z"),
            item("all day", "2026-11-27T05:00:00Z", "2026-11-28T05:00:00Z", allDay: true),
            item("canceled", "2026-11-27T15:00:00Z", "2026-11-27T16:00:00Z", canceled: true)]
        store.refresh(at: date("2026-11-27T17:00:00Z"), calendar: calendar)
        XCTAssertEqual(store.items.map(\.id), ["all day", "overnight", "later"])
        store.refresh(at: date("2026-11-28T17:00:00Z"), calendar: calendar)
        XCTAssertEqual(store.items.map(\.id), ["tomorrow"])
    }
    func testLocalDayAcrossDSTUses23And25HourWindows() {
        store.sageID = "apple"
        for (now, start, end, hours) in [
            ("2026-03-08T16:00:00Z", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
            ("2026-11-01T16:00:00Z", "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0)] {
            store.refresh(at: date(now), calendar: calendar)
            XCTAssertEqual(reader.queries.last?.0.start, date(start))
            XCTAssertEqual(reader.queries.last?.0.end, date(end))
            XCTAssertEqual(reader.queries.last!.0.duration, hours * 3600)
        }
    }
    func testSelectionsPersistLocallyAndCanBeCleared() {
        store.sageID = "apple"; store.danID = "google"
        let reopened = DashboardCalendarStore(defaults: defaults, reader: reader)
        XCTAssertEqual(reopened.sageID, "apple"); XCTAssertEqual(reopened.danID, "google")
        store.sageID = ""; store.danID = ""
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(DashboardCalendarStore(defaults: defaults, reader: reader).sageID, "")
    }
    func testDeniedAndRevokedAccessClearEventsWithoutQuerying() {
        store.sageID = "apple"
        reader.events = [item("meeting", "2026-11-27T15:00:00Z", "2026-11-27T16:00:00Z")]
        store.refresh(at: date("2026-11-27T17:00:00Z"), calendar: calendar)
        XCTAssertEqual(store.items.count, 1)
        let count = reader.queries.count
        for status in [EKAuthorizationStatus.denied, .restricted, .writeOnly, .notDetermined] {
            reader.authorizationStatus = status
            store.refresh()
            XCTAssertFalse(store.authorized); XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.choices.isEmpty)
            XCTAssertNotNil(store.message)
        }
        XCTAssertEqual(reader.queries.count, count)
        XCTAssertEqual(reader.accessRequests, 0)
    }
    func testConnectGrantDenialAndFailure() async {
        reader.authorizationStatus = .notDetermined
        await store.connect()
        XCTAssertTrue(store.authorized); XCTAssertEqual(reader.resets, 1); XCTAssertFalse(store.requesting)
        reader.grant = false
        await store.connect()
        XCTAssertFalse(store.authorized); XCTAssertEqual(reader.resets, 1)
        reader.failure = NSError(domain: "CalendarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar unavailable"])
        await store.connect()
        XCTAssertEqual(store.message, "Calendar unavailable"); XCTAssertFalse(store.requesting)
    }
}
