"""Verify one-off payment due groups across date boundaries and payment history."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
model = 'import Foundation\n' + app[app.index('struct MoneyEntry:'):app.index('struct LastTimeEntry:')]
checks = r'''
@main struct PaymentChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 23))!
        var payment = PaymentDue(title: "Piano lessons", cents: 7500, day: "2026-11-17")
        precondition(payment.group(today: today, calendar: calendar) == .overdue)
        payment.day = "2026-11-18"
        precondition(payment.group(today: today, calendar: calendar) == .today)
        payment.day = "2026-11-19"
        precondition(payment.group(today: today, calendar: calendar) == .soon)
        payment.day = "2026-11-25"
        precondition(payment.group(today: today, calendar: calendar) == .soon)
        payment.day = "2026-11-26"
        precondition(payment.group(today: today, calendar: calendar) == .later)
        payment.paidAt = today
        payment.notes = "Two lessons"
        precondition(payment.group(today: today, calendar: calendar) == .paid)
        payment.day = "2026-01-01"
        precondition(payment.group(today: today, calendar: calendar) == .paid)
        payment.paidAt = nil
        precondition(payment.group(today: today, calendar: calendar) == .overdue)
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23))!
        payment.day = "2026-03-14"
        precondition(payment.group(today: spring, calendar: calendar) == .soon)
        let decoded = try JSONDecoder().decode(PaymentDue.self, from: JSONEncoder().encode(payment))
        precondition(decoded == payment)
        print("Things To Pay checks passed: overdue, today, seven-day boundary, DST, paid/unpaid, and encoding.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-payments-checks-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(model + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
