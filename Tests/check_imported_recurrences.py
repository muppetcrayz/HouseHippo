"""Focused recurrence tests, using independent calendar-day expectations for actual imported rules.
Does not build either app, access EventKit, modify the live database, or contact iCloud.
"""
from pathlib import Path
import calendar, datetime as dt, json, os, subprocess, tempfile
from zoneinfo import ZoneInfo
root = Path(__file__).resolve().parents[1]
zone = ZoneInfo('America/New_York')
epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
fixtures = json.loads((root/'Tests/Fixtures/imported_recurrences.json').read_text())
for fixture in fixtures:
    anchor = (epoch + dt.timedelta(seconds=fixture['date'])).astimezone(zone)
    fields = dict(part.split('=', 1) for part in fixture['rule'].removeprefix('RRULE ').split(';'))
    interval = int(fields.get('INTERVAL', 1))
    until = dt.datetime.strptime(fields['UNTIL'], '%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc) if 'UNTIL' in fields else None
    weekdays = {'MO':0, 'TU':1, 'WE':2, 'TH':3, 'FR':4, 'SA':5, 'SU':6}
    selected = {weekdays[x] for x in fields['BYDAY'].split(',')} if 'BYDAY' in fields else {anchor.weekday()}
    expected = []
    # Enumerate calendar dates independently of the Swift next-occurrence implementation.
    for offset in range(4000):
        day = anchor.date() + dt.timedelta(days=offset)
        candidate = dt.datetime.combine(day, anchor.timetz(), zone)
        if until and candidate > until: break
        freq = fields['FREQ']
        if freq == 'DAILY': matches = offset % interval == 0
        elif freq == 'WEEKLY':
            monday = day - dt.timedelta(days=day.weekday())
            first_monday = anchor.date() - dt.timedelta(days=anchor.weekday())
            matches = ((monday-first_monday).days//7) % interval == 0 and day.weekday() in selected
        else:
            month_diff = (day.year-anchor.year)*12 + day.month-anchor.month
            last_day = calendar.monthrange(day.year, day.month)[1]
            if fields.get('BYSETPOS') == '-1' or fields.get('BYMONTHDAY') == '-1': target = last_day
            else: target = int(fields.get('BYMONTHDAY', anchor.day))
            matches = month_diff % interval == 0 and day.day == target
        if matches:
            expected.append((candidate.astimezone(dt.timezone.utc)-epoch).total_seconds())
            if len(expected) == 40: break
    fixture['expected'] = expected
app = (root/'HouseHippo/HouseHippoApp.swift').read_text()
model = app[app.index('struct Reminder:'):app.index('final class NotificationDelegate')]
checks = r'''
NSTimeZone.default = TimeZone(identifier: "America/New_York")!
struct Fixture: Decodable { let rule: String; let date: Double; let completed: Bool; let expected: [Double] }
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var matched = 0
for fixture in fixtures {
    let anchor = Date(timeIntervalSinceReferenceDate: fixture.date)
    var task = Reminder(title: "Fixture", message: "", date: anchor, frequency: .once)
    task.list = "Chores"
    task.notes = "User's own notes\n\nImported repeating reminder. Review its repeat schedule in HouseHippo. Original rule: EKRecurrenceRule <redacted> " + fixture.rule
    task.matchImportedRecurrence()
    precondition(task.recurrenceReviewReason == nil, fixture.rule + ": " + (task.recurrenceReviewReason ?? ""))
    precondition(!task.summary.lowercased().contains("review"))
    precondition(task.notes == "User's own notes")
    precondition(task.originalRecurrenceRule != nil)
    var cursor = anchor.addingTimeInterval(-1)
    for expected in fixture.expected {
        guard let next = task.nextScheduledOccurrence(after: cursor) else { fatalError("Missing occurrence for " + fixture.rule) }
        precondition(abs(next.timeIntervalSinceReferenceDate-expected) < 0.01, "Wrong date for " + fixture.rule + ": " + next.description)
        cursor = next
    }
    if fixture.expected.count < 40 { precondition(task.nextScheduledOccurrence(after: cursor) == nil) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let saved = try encoder.encode(task)
    var restored = try JSONDecoder().decode(Reminder.self, from: saved)
    restored.matchImportedRecurrence()
    precondition(try encoder.encode(restored) == saved)
    matched += 1
}
for raw in ["RRULE FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "RRULE FREQ=WEEKLY;COUNT=4", "RRULE FREQ=YEARLY", "RRULE FREQ=DAILY;INTERVAL=0", "RRULE FREQ=DAILY;BOGUS=1", "RRULE FREQ=WEEKLY;BYDAY=NO", "RRULE FREQ=DAILY;UNTIL=bad", "RRULE FREQ=DAILY;FREQ=WEEKLY", "RRULE FREQ=WEEKLY; RRULE FREQ=DAILY"] {
    var task = Reminder(title: "Review", message: "", date: Date(), frequency: .once)
    task.originalRecurrenceRule = raw
    task.matchImportedRecurrence()
    precondition(task.recurrenceReviewReason != nil, "Unrepresentable rule was silently accepted: " + raw)
    precondition(task.frequency == .once)
}
var manual = Reminder(title: "Edited by Sage", message: "", date: Date(), frequency: .weekly)
manual.selectedWeekdays = [1,3,5]
manual.originalRecurrenceRule = "RRULE FREQ=DAILY;INTERVAL=1"
manual.matchImportedRecurrence()
precondition(manual.frequency == .weekly && manual.weekdays == [1,3,5] && manual.recurrenceReviewReason == nil)
var trailingNotes = Reminder(title: "Notes", message: "", date: Date(), frequency: .once)
trailingNotes.notes = "Before\n\nImported repeating reminder. Review its repeat schedule in HouseHippo. Original rule: RRULE FREQ=DAILY;INTERVAL=1\nAfter: keep this note"
trailingNotes.matchImportedRecurrence()
precondition(trailingNotes.notes == "Before\nAfter: keep this note")
precondition(trailingNotes.recurrenceReviewReason == nil)
print("Matched all \(matched) saved rules against independent calendar expectations (up to 40 occurrences each), including every other week, custom day intervals, month ends, leap years, DST and end dates. Unsupported rules request review; user edits and notes survive; migration is idempotent.")
'''
checks = checks.replace('precondition(try encoder.encode(restored) == saved)', 'let savedAgain = try encoder.encode(restored); precondition(savedAgain == saved)')
with tempfile.TemporaryDirectory(prefix='HouseHippo-rule-checks-') as directory:
    directory = Path(directory)
    (directory/'Fixtures.json').write_text(json.dumps(fixtures))
    (directory/'Checks.swift').write_text('import Foundation\n' + model + (root/'HouseHippo/Recurrence.swift').read_text() + checks)
    subprocess.run(['swift', '-module-cache-path', str(directory/'cache'), str(directory/'Checks.swift'), str(directory/'Fixtures.json')], check=True, env={**os.environ, 'TZ':'America/New_York'})
