"""Compile the actual bill models and check import and pay-period boundaries."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
model = 'import Foundation\n' + app[app.index('struct MoneyEntry:'):app.index('struct LastTimeEntry:')]
checks = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        var dan = BudgetPaycheck.estimate(for: "Dan")
        dan.hours = "20.75"
        var sage = BudgetPaycheck.estimate(for: "Sage")
        sage.hours = "33.25"
        precondition(BudgetPaycheck.roundedCents(dan.netAmount!) == 87134)
        precondition(BudgetPaycheck.roundedCents(sage.netAmount!) == 139679)
        var budget = PayPeriodBudget(startDay: "2026-11-27", paychecks: [dan, sage])
        precondition(budget.incomeCents == 226814) // Numbers totals unrounded estimates.
        precondition(budget.freeSpendingCents(billsCents: 200000) == 24314)
        budget.additionalDebtCents = 10000; budget.savingsCents = 5000; budget.carryoverCents = 20000
        precondition(budget.freeSpendingCents(billsCents: 200000) == -10686)
        precondition(budget.freeSpendingCents(billsCents: 200000, priorCarryoverCents: 30000) == 19314)
        budget.includePriorCarryover = false
        precondition(budget.freeSpendingCents(billsCents: 200000, priorCarryoverCents: 30000) == -10686)
        budget.includePriorCarryover = true
        budget.carryoverCents = -20000
        precondition(budget.freeSpendingCents(billsCents: 200000) == 29314)
        var actual = BudgetPaycheck(name: "Paycheck", actualAmount: "0.00")
        budget.paychecks = [actual]
        precondition(budget.incomeCents == 0)
        actual.actualAmount = "1534.36"; budget.paychecks = [actual]
        precondition(budget.incomeCents == 153436)
        actual.actualAmount = ""; budget.paychecks = [actual]
        precondition(budget.incomeCents == nil && budget.freeSpendingCents(billsCents: 0) == nil)
        budget.paychecks = []
        precondition(budget.incomeCents == nil)
        dan.hours = "-1"; precondition(dan.netAmount == nil)
        dan.hours = "20.75"; dan.takeHomePercent = "101"; precondition(dan.netAmount == nil)
        dan.takeHomePercent = "89.574445"; dan.hourlyRate = "46.888"; precondition(dan.netAmount == nil)
        budget.paychecks = [BudgetPaycheck(name: "One", actualAmount: "400"), BudgetPaycheck(name: "Two", actualAmount: "400"), BudgetPaycheck(name: "Three", actualAmount: "1534.36"), BudgetPaycheck(name: "Four", actualAmount: "833.95")]
        budget.additionalDebtCents = 0; budget.savingsCents = 0; budget.carryoverCents = 0
        precondition(budget.incomeCents == 316831 && budget.freeSpendingCents(billsCents: 0) == 314331)
        let budgetDecoded = try JSONDecoder().decode(PayPeriodBudget.self, from: JSONEncoder().encode(budget))
        precondition(budgetDecoded == budget)
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: String) -> Date { MoneyEntry(person: "", title: "", day: day, cents: 0).date }
        let anchor = date("2026-11-27")
        precondition(RecurringBill.periodStart(containing: date("2026-11-26"), anchor: anchor) == date("2026-11-13"))
        precondition(RecurringBill.periodStart(containing: date("2026-12-10"), anchor: anchor) == anchor)
        precondition(RecurringBill.periodStart(containing: date("2026-12-11"), anchor: anchor) == date("2026-12-11"))
        var bill = RecurringBill(title: "Rent", cents: 10000, day: "2020-12-01")
        precondition(bill.occurrences(from: anchor, to: date("2026-12-11")) == [date("2026-12-01")])
        bill.day = "2026-11-27"
        precondition(bill.occurrences(from: anchor, to: date("2026-12-11")) == [anchor])
        bill.day = "2026-12-11"
        precondition(bill.occurrences(from: anchor, to: date("2026-12-11")).isEmpty)
        bill.day = "2024-02-29"; bill.yearly = true
        precondition(bill.occurrences(from: date("2025-01-01"), to: date("2029-01-01")) == [date("2028-02-29")])
        bill.yearly = false; bill.day = "2026-01-31"; bill.count = 2
        precondition(bill.occurrences(from: date("2026-01-01"), to: date("2026-05-01")) == [date("2026-01-31"), date("2026-03-31")])
        var expired = RecurringBill(title: "Old", cents: 100, day: "2020-01-01")
        expired.until = "2026-10-31"
        precondition(!expired.isActiveInBudgetYear)
        expired.until = "2026-11-01"
        precondition(expired.isActiveInBudgetYear) // Lower boundary included.
        expired.until = nil; expired.count = 2
        precondition(!expired.isActiveInBudgetYear)
        expired.count = nil; expired.day = "2027-11-01"
        precondition(!expired.isActiveInBudgetYear) // Upper boundary excluded.
        expired.day = "2027-10-31"
        precondition(expired.isActiveInBudgetYear)
        expired.day = "2020-06-01"; expired.yearly = true
        precondition(expired.isActiveInBudgetYear) // Old DTSTART alone does not mean expired.
        expired.excluded = ["2027-06-01"]
        precondition(!expired.isActiveInBudgetYear)
        let source = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:rent
        DTSTART;VALUE=DATE:20200101
        SUMMARY:Rent $1,200.50
        RRULE:FREQ=MONTHLY;BYMONTHDAY=1
        EXDATE;VALUE=DATE:20261201
        END:VEVENT
        BEGIN:VEVENT
        UID:annual
        DTSTART;TZID=America/New_York:20260610T090000
        SUMMARY:Annual bill
         continued
        RRULE:FREQ=YEARLY;UNTIL=20280610T130000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:unsupported
        DTSTART:20261101
        SUMMARY:Weekly
        RRULE:FREQ=WEEKLY
        END:VEVENT
        END:VCALENDAR
        """
        let inactiveSource = source.replacingOccurrences(of: "END:VCALENDAR", with: "BEGIN:VEVENT\nUID:expired\nDTSTART:20200101\nSUMMARY:Expired\nRRULE:FREQ=MONTHLY;UNTIL=20261031\nEND:VEVENT\nBEGIN:VEVENT\nUID:future\nDTSTART:20271101\nSUMMARY:Future\nRRULE:FREQ=YEARLY\nEND:VEVENT\nEND:VCALENDAR")
        let inactivePreview = try BillCalendarImport.parse(inactiveSource)
        precondition(inactivePreview.bills.count == 2 && inactivePreview.inactiveCount == 2)
        let preview = try BillCalendarImport.parse(source)
        precondition(preview.bills.count == 2 && preview.warnings.count == 1)
        precondition(preview.bills[0].cents == 120050)
        precondition(preview.bills[0].occurrences(from: anchor, to: date("2026-12-11")).isEmpty)
        precondition(preview.bills[1].title == "Annual billcontinued" && preview.bills[1].cents == 0)
        precondition(preview.bills[1].occurrences(from: date("2029-01-01"), to: date("2030-01-01")).isEmpty)
        let exception = source.replacingOccurrences(of: "END:VCALENDAR", with: "BEGIN:VEVENT\nUID:rent\nRECURRENCE-ID:20261201\nDTSTART:20261202\nEND:VEVENT\nEND:VCALENDAR")
        let changedPreview = try BillCalendarImport.parse(exception)
        precondition(changedPreview.bills.count == 1)
        let roundtrip = try JSONDecoder().decode(RecurringBill.self, from: JSONEncoder().encode(preview.bills[0]))
        precondition(roundtrip == preview.bills[0])
        let spring = RecurringBill.periodStart(containing: date("2027-03-18"), anchor: anchor, calendar: calendar)
        precondition(calendar.component(.weekday, from: spring) == 6)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ics")
        defer { try? FileManager.default.removeItem(at: url) }
        let manyEvents = (0..<1000).map { "BEGIN:VEVENT\nUID:stress-\($0)\nDTSTART:20000101\nSUMMARY:Bill $10\nRRULE:FREQ=MONTHLY\nEND:VEVENT" }.joined(separator: "\n")
        try ("BEGIN:VCALENDAR\n" + manyEvents + "\nEND:VCALENDAR").write(to: url, atomically: true, encoding: .utf8)
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(1)) }
        }
        let clock = ContinuousClock(); let began = clock.now
        let loaded = try await BillCalendarImport.load(url)
        ticker.cancel()
        precondition(loaded.bills.count == 1000 && ticks > 0)
        let cancelled = Task { try await BillCalendarImport.load(url) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled import succeeded") } catch is CancellationError {}
        print("Background parsing: 1000 old series in \(began.duration(to: clock.now)), main actor serviced \(ticks) ticks; cancellation passed.")
        func amountSource(_ description: String) -> String {
            "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:amount-check\nSUMMARY:Water bill\nDTSTART;VALUE=DATE:20261205\nRRULE:FREQ=MONTHLY\nDESCRIPTION:\(description)\nEND:VEVENT\nEND:VCALENDAR\n"
        }
        for (description, cents) in [("Pay $50", 5000), ("Pay $50.", 5000), ("Amount: $1,234.56.", 123456), ("Autopay $42.10, card on file", 4210),
                                     ("$85 (approx)", 8500), ("Total $1,234", 123400), ("About $12.345", 0), ("Odd $1,2345", 0), ("Pay $5 or $6", 0)] {
            let proposed = try BillCalendarImport.parse(amountSource(description)).bills.first?.cents
            precondition(proposed == cents, "Amount for " + description)
        }
        print("Calendar amount checks passed: sentence-ending periods and commas, thousands separators, malformed and ambiguous values.")
        print("Budget and recurring checks passed: source paycheck/formula matches, unrounded totals, actual/estimated income, missing/zero inputs, signed allocations, imports, exclusions, bounds, leap years, month ends, payday boundaries, DST, encoding.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-recurring-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(model + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
