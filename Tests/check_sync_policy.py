"""Exercise merge decisions and the actual task wire codec. No Apple apps or live stores are touched."""
from pathlib import Path
import datetime as dt, json, os, subprocess, tempfile
from zoneinfo import ZoneInfo
root = Path(__file__).resolve().parents[1]
app = (root/'HouseHippo/HouseHippoApp.swift').read_text()
model = app[app.index('struct Reminder:'):app.index('final class NotificationDelegate')]
fixtures = json.loads((root/'Tests/Fixtures/imported_recurrences.json').read_text())
epoch = dt.datetime(2001,1,1,tzinfo=dt.timezone.utc)
codes = ['SU','MO','TU','WE','TH','FR','SA']
for f in fixtures:
    fields = dict(x.split('=',1) for x in f['rule'].removeprefix('RRULE ').split(';'))
    date = (epoch + dt.timedelta(seconds=f['date'])).astimezone(ZoneInfo('America/New_York'))
    canonical = 'RRULE FREQ=' + fields['FREQ'] + ';INTERVAL=' + fields.get('INTERVAL','1')
    if fields['FREQ'] == 'WEEKLY':
        days = set(fields.get('BYDAY', codes[(date.weekday()+1)%7]).split(','))
        canonical += ';BYDAY=' + ','.join(x for x in codes if x in days)
    if fields['FREQ'] == 'MONTHLY':
        day = '-1' if fields.get('BYSETPOS') == '-1' else fields.get('BYMONTHDAY',str(date.day))
        canonical += ';BYMONTHDAY=' + day
    if 'UNTIL' in fields: canonical += ';UNTIL=' + fields['UNTIL']
    f['canonical'] = canonical
checks = r'''
NSTimeZone.default = TimeZone(identifier: "America/New_York")!
let a=Data("a".utf8), b=Data("b".utf8), c=Data("c".utf8)
precondition(AppleSyncPolicy.action(base:a,local:a,remote:a) == .acknowledge)
precondition(AppleSyncPolicy.action(base:a,local:b,remote:a) == .push)
precondition(AppleSyncPolicy.action(base:a,local:a,remote:b) == .pull)
precondition(AppleSyncPolicy.action(base:a,local:b,remote:b) == .acknowledge)
precondition(AppleSyncPolicy.action(base:a,local:b,remote:c) == .conflict)
precondition(AppleSyncPolicy.action(base:a,local:nil,remote:a) == .push)
precondition(AppleSyncPolicy.action(base:a,local:a,remote:nil) == .pull)
precondition(AppleSyncPolicy.action(base:a,local:nil,remote:b) == .conflict)
precondition(AppleSyncPolicy.action(base:a,local:b,remote:nil) == .conflict)
precondition(AppleSyncPolicy.action(base:nil,local:a,remote:b) == .conflict)
precondition(AppleSyncPolicy.action(base:nil,local:nil,remote:a) == .conflict)
precondition(AppleSyncPolicy.action(base:nil,local:nil,remote:nil) == .acknowledge)
// Replaying an acknowledged edit or deletion cannot generate another outbound write.
precondition(AppleSyncPolicy.action(base:b,local:b,remote:b) == .acknowledge)
let payload=SyncedNoteValue(title:"<Title> & \"quotes\"",body:"One\n<script>bad</script>")
precondition(payload.html.contains("&lt;script&gt;"))
precondition(!payload.html.contains("<script>"))
precondition(SyncedNoteValue.removingTitle("Title\nBody",title:"Title") == "Body")
precondition(SyncedNoteValue.removingTitle("Body",title:"Title") == "Body")
let pending=PendingAppleNoteCreation(value:payload,previouslyVisibleIDs:["already-here"])
let restored=try JSONDecoder().decode(PendingAppleNoteCreation.self,from:appleSyncData(pending))
precondition(restored.value == payload && restored.previouslyVisibleIDs == ["already-here"])
struct Fixture:Decodable {let date:Double;let completed:Bool;let rule:String;let canonical:String}
let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
for fixture in fixtures {
    var task=Reminder(title:"Fixture",message:"",date:Date(timeIntervalSinceReferenceDate:fixture.date),frequency:.once)
    task.completed=fixture.completed
    task.originalRecurrenceRule=fixture.rule
    task.matchImportedRecurrence()
    let wire=try AppleRemindersAdapter.taskValue(task,calendarID:"chosen-list")
    precondition(wire.rule == fixture.canonical, fixture.rule + " => " + (wire.rule ?? "nil"))
    precondition(wire.completed == fixture.completed && wire.calendarID == "chosen-list")
    let before=try appleSyncData(wire)
    task.linkedNoteID=UUID()
    task.notes="HouseHippo note links do not belong in Reminders note fields"
    let independent=try AppleRemindersAdapter.taskValue(task,calendarID:"chosen-list")
    precondition(try appleSyncData(independent) == before)
}
var completed=Reminder(title:"Task",message:"",date:Date(),frequency:.once)
let activeData=try appleSyncData(AppleRemindersAdapter.taskValue(completed,calendarID:"list"))
completed.completed=true
let completeData=try appleSyncData(AppleRemindersAdapter.taskValue(completed,calendarID:"list"))
precondition(AppleSyncPolicy.action(base:activeData,local:completeData,remote:activeData) == .push)
var undated=Reminder(title:"Any time",message:"",date:Date(),frequency:.anytime)
precondition(!undated.syncsWithAppleReminders)
undated.frequency = .once; undated.hasDueDate = false
precondition(!undated.syncsWithAppleReminders)
undated.hasDueDate = true
precondition(undated.syncsWithAppleReminders)
undated.kind = .notification
precondition(!undated.syncsWithAppleReminders)
var flexible=Reminder(title:"Month window",message:"",date:Date(),frequency:.flexible)
precondition(!flexible.syncsWithAppleReminders)
do {_ = try AppleRemindersAdapter.taskValue(flexible,calendarID:"list");fatalError("Flexible window silently approximated")}catch{}
print("Sync checks passed: three-way edits/deletions, concurrent edit/delete conflicts, initial conflicts, no ping-pong, durable creation intent, HTML escaping, all 67 recurrence wire mappings, completion and independent note links.")
'''
checks=checks.replace('precondition(try appleSyncData(independent) == before)','let independentData = try appleSyncData(independent); precondition(independentData == before)')
with tempfile.TemporaryDirectory(prefix='HouseHippo-sync-checks-') as directory:
    directory=Path(directory)
    (directory/'Fixtures.json').write_text(json.dumps(fixtures))
    (directory/'Checks.swift').write_text('import Foundation\n'+model+(root/'HouseHippo/Recurrence.swift').read_text()+(root/'HouseHippo/SyncPolicy.swift').read_text()+(root/'HouseHippo/AppleRemindersSync.swift').read_text()+checks)
    subprocess.run(['swift','-module-cache-path',str(directory/'cache'),str(directory/'Checks.swift'),str(directory/'Fixtures.json')],check=True,env={**os.environ,'TZ':'America/New_York'})
