"""Run the actual sync pass with in-memory adapters; never access live reminders or storage."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
app = (root/'HouseHippo/HouseHippoApp.swift').read_text()
model = app[app.index('struct Reminder:'):app.index('final class NotificationDelegate')]
service = (root/'HouseHippo/AppleSync.swift').read_text().split('\nstruct AppleSyncControls:')[0]
service = service.replace('private var checkpoints:', 'var checkpoints:').replace('private func run() async', 'func run() async')
a = service.index('    var deviceID: String {'); b = service.index('    private struct State:', a)
service = service[:a] + '    var deviceID: String { "test-device" }\n' + service[b:]
a = service.index('    private func persist() throws {'); b = service.index('    private func conflict(', a)
service = service[:a] + '    private func persist() throws {}\n' + service[b:]
adapter = (root/'HouseHippo/AppleRemindersSync.swift').read_text()
error_type = adapter[adapter.index('struct AppleRemindersWriteFailure:'):adapter.index('@MainActor final class AppleRemindersAdapter')]
stubs = r'''
struct FakeCalendar { var calendarIdentifier = "list"; var title = "Home" }
final class FakeReminder {
    var calendarItemIdentifier: String
    var calendarItemExternalIdentifier: String? { calendarItemIdentifier }
    var calendar = FakeCalendar()
    var title: String?
    var isCompleted = false
    var completionDate: Date?
    var url: URL?
    var wire: SyncedTaskValue
    init(_ id: String, _ value: SyncedTaskValue) { calendarItemIdentifier = id; title = value.title; wire = value }
}
@MainActor final class CloudStore: ObservableObject {
    static let shared = CloudStore()
    static func appleNoteID(sourceID: String) -> UUID { fatalError("Unexpected import") }
    @Published var revision = 0
    var records: [Reminder] = []
    var config = AppleSyncSettings()
    func read(_ key: String) throws -> Data? { try appleSyncData(config) }
    func put(_ data: Data, key: String) throws {}
    func tasks(includeDeleted: Bool = false) throws -> [Reminder] { records }
    func save(_ task: Reminder) throws { records[records.firstIndex { $0.id == task.id }!] = task }
    func delete(_ task: Reminder) throws { fatalError("Unexpected deletion") }
    func retireCompletedTask(_ task: Reminder) throws { fatalError("Unexpected retirement") }
}
@MainActor final class AppleRemindersAdapter {
    let events = NSObject()
    var items: [FakeReminder] = []
    var attempts: [String] = []
    func snapshot(settings: AppleSyncSettings, known: [AppleSyncCheckpoint]) async throws -> [FakeReminder] { items }
    static func listName(_ name: String) -> String { name }
    func localValue(_ task: Reminder, settings: AppleSyncSettings) throws -> SyncedTaskValue {
        SyncedTaskValue(title: task.title, calendarID: "list", date: task.date, allDay: true, completed: task.completed, rule: nil)
    }
    func value(_ item: FakeReminder) throws -> SyncedTaskValue { item.wire }
    func update(_ item: FakeReminder, expected: SyncedTaskValue, desired: SyncedTaskValue, completionDate: Date? = nil) throws -> FakeReminder {
        attempts.append(item.calendarItemIdentifier)
        if item.calendarItemIdentifier == "fail" {
            throw AppleRemindersWriteFailure(operation: "update reminder", underlying: NSError(domain: "com.apple.reminderkit", code: -3002), movingLists: true)
        }
        item.wire = desired
        return item
    }
    func create(taskID: UUID, desired: SyncedTaskValue) throws -> FakeReminder { fatalError("Unexpected creation") }
    func complete(_ source: FakeReminder, expected: SyncedTaskValue, date: Date) throws { fatalError("Unexpected completion") }
    func delete(_ source: FakeReminder, expected: SyncedTaskValue) throws { fatalError("Unexpected deletion") }
    func apply(_ value: SyncedTaskValue, to task: inout Reminder, source: FakeReminder, owner: Reminder.Owner) { task.title = value.title }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let db = CloudStore.shared
        let sync = AppleSyncService()
        db.config.enabled = true; db.config.deviceID = "test-device"; db.config.calendarIDs = ["list"]
        let date = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        var failed = Reminder(title: "Failed local edit", message: "", date: date, frequency: .once)
        failed.sourceID = "fail"
        var pushed = Reminder(title: "Successful local edit", message: "", date: date, frequency: .once)
        pushed.sourceID = "push"
        var pulled = Reminder(title: "Old local title", message: "", date: date, frequency: .once)
        pulled.sourceID = "pull"
        db.records = [failed, pushed, pulled]
        for task in db.records {
            var base = try sync.reminders.localValue(task, settings: db.config)
            if task.sourceID != "pull" { base.title = "Old remote title" }
            let key = "task." + task.id.uuidString
            sync.checkpoints[key] = AppleSyncCheckpoint(sourceID: task.sourceID!, base: try appleSyncData(base))
            var remote = base
            if task.sourceID == "pull" { remote.title = "Successful Apple edit" }
            sync.reminders.items.append(FakeReminder(task.sourceID!, remote))
        }
        let failedBase = sync.checkpoints["task." + failed.id.uuidString]?.base
        await sync.run()
        precondition(sync.reminders.attempts == ["fail", "push"])
        precondition(sync.reminders.items[1].wire.title == pushed.title)
        precondition(db.records[2].title == "Successful Apple edit")
        precondition(sync.checkpoints["task." + failed.id.uuidString]?.base == failedBase)
        precondition(sync.conflicts.contains { $0.title == failed.title && !$0.canChoose && $0.explanation.contains("Move it in Reminders") })
        await sync.run()
        precondition(sync.reminders.attempts == ["fail", "push", "fail"])
        precondition(db.records[2].title == "Successful Apple edit")
        print("Sync failure checks passed: failed write keeps its checkpoint, unrelated pushes and pulls finish, task-specific error shown, retry does not repeat successful writes.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-sync-failures-') as directory:
    path = Path(directory)
    source = 'import Foundation\nimport Combine\n' + model + (root/'HouseHippo/Recurrence.swift').read_text() + (root/'HouseHippo/SyncPolicy.swift').read_text() + error_type + stubs + service
    (path/'Checks.swift').write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path/'cache'), str(path/'Checks.swift'), '-o', str(path/'checks')], check=True)
    subprocess.run([str(path/'checks')], check=True)
