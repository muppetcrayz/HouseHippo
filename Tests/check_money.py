"""Check exact money arithmetic, pasted lists, calendar validation and summaries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
model = 'import Foundation\n' + app[app.index('struct MoneyEntry:'):app.index('struct LastTimeEntry:')]
checks = r'''
@main struct MoneyChecks {
    static func main() throws {
        let list = """
        5/1 - Pheromones - +8.88
        5/9 - Farmer’s Market - +24.30
        5/10 - Kroger - +4.33
        5/16 - Farmer’s Market - +22.00
        5/16 - Aldi - +24.57
        5/17 - Cat Food - +18.14
        5/17 - Kroger - +15.46
        5/23 - Farmer’s Market - +43.96
        5/23 - Kroger - +58.68
        5/25 - Table - -100.00
        5/30 - Farmer’s Market - +45.49
        5/30 - Kroger - +54.17
        6/7 - Pyrex - -15.00
        6/11 - Slow Cooker - -25.00
        6/11 - Camera - -20.00
        6/11 - Gas - +50.00
        7/18 - Meat Thermometer - -15.00
        11/3 - YouTube Premium - +56.00
        11/2 - Laptop - +400.00
        11/4 - Cat Toys - -10.00

        +640.98
        """
        let entries = try MoneyEntry.parse(list, person: "Friend", year: 2026)
        precondition(entries.count == 20)
        precondition(MoneyEntry.balance(entries) == 64098)
        precondition(MoneyEntry.ordered(entries).last?.day == "2026-11-04")
        let summary = MoneyEntry.summary(person: "Friend", entries: entries)
        precondition(summary.contains("You owe me $640.98."))
        precondition(summary.contains("Table - -$100.00"))
        precondition(summary.contains("Net total: +$640.98"))
        precondition(MoneyEntry.paymentCents(10000, balance: 64098) == -10000)
        precondition(MoneyEntry.paymentCents(64098, balance: 64098) == -64098)
        precondition(MoneyEntry.paymentCents(500, balance: -1000) == 500)
        precondition(MoneyEntry.paymentCents(1000, balance: -1000) == 1000)
        precondition(MoneyEntry.paymentCents(0, balance: 1000) == nil)
        precondition(MoneyEntry.paymentCents(-100, balance: 1000) == nil)
        precondition(MoneyEntry.paymentCents(1001, balance: 1000) == nil)
        precondition(MoneyEntry.paymentCents(100, balance: 0) == nil)
        let payment = MoneyEntry(person: "Friend", title: "Repaid", day: "2026-11-18", cents: -64098)
        precondition(MoneyEntry.balance(entries + [payment]) == 0)
        precondition(MoneyEntry.summary(person: "Friend", entries: entries + [payment]).contains("settled up"))
        precondition(MoneyEntry.summary(person: "Friend", entries: [payment]).contains("I owe you $640.98."))
        precondition(MoneyEntry.amount("0.10") == 10)
        precondition(MoneyEntry.amount("-0.01") == -1)
        for invalid in ["1.234", "1,20", "nan", "1e4", "9999999999999999999999", "", "+"] {
            precondition(MoneyEntry.amount(invalid) == nil)
        }
        for invalid in ["2/30 - Bad date - +10.00", "2/29 - Bad leap year - +10.00", "13/1 - Bad month - +10.00", "5/1 - Missing amount", "5/1 - Bad cents - +1.234", "5/1 - Zero - 0.00", "+640.98"] {
            do { _ = try MoneyEntry.parse(invalid, person: "Friend", year: 2026); preconditionFailure("Accepted invalid list") }
            catch is MoneyEntry.ImportError {}
        }
        let leap = try MoneyEntry.parse("2/29 - Leap day - +1.00", person: "Friend", year: 2024)
        precondition(leap[0].day == "2024-02-29")
        let decoded = try JSONDecoder().decode([MoneyEntry].self, from: JSONEncoder().encode(entries))
        precondition(decoded == entries)
        print("Money checks passed: 20-entry sample totals $640.98; exact cents, repayments, summaries, dates, invalid imports, and encoding.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-money-checks-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(model + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
