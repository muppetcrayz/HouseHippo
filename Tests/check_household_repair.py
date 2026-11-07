"""Verify snapshot-specific duplicate repair in isolated stores, optionally using supplied backups."""
from pathlib import Path
import subprocess, tempfile, sys
root = Path(__file__).resolve().parents[1]
app = (root/'HouseHippo/HouseHippoApp.swift').read_text()
model = app[app.index('struct Reminder:'):app.index('final class NotificationDelegate')]
model += (root/'HouseHippo/GroceryModel.swift').read_text() + (root/'HouseHippo/Recurrence.swift').read_text()
store = (root/'HouseHippo/CloudStore.swift').read_text()
checks = r'''
@main struct RepairChecks {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HouseHippo.repair." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        let db = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let decoder = JSONDecoder()
        let repairData: Data
        if CommandLine.arguments.count == 3 {
            _ = try db.importBackup(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            repairData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        } else {
            var canonical = Reminder(title: "Shared task", message: "", date: Date(), frequency: .daily)
            canonical.sourceID = "same-apple-reminder"
            var duplicate = canonical; duplicate.id = UUID()
            duplicate.markCompleted()
            var merged = duplicate; merged.id = canonical.id
            let other = Reminder(title: "Unique task", message: "", date: Date(), frequency: .once)
            try db.saveAll([canonical, duplicate, other])
            repairData = try JSONEncoder().encode(CloudStore.TaskRepair(format: "HouseHippoTaskRepair", version: 1, pairs: [.init(duplicate: duplicate, canonical: canonical, merged: merged)]))
        }
        let repair = try decoder.decode(CloudStore.TaskRepair.self, from: repairData)
        let before = try db.tasks(includeDeleted: true)
        let snapshot = try db.exportBackup()
        let repairIDs = Set(repair.pairs.flatMap { [$0.duplicate.id, $0.canonical.id] })
        let unchanged = before.filter { !repairIDs.contains($0.id) }
        let beforeNotes = try db.notes(includeHidden: true)
        let first = repair.pairs[0]
        // Changes after backup must reject the entire plan, before writing any markers.
        var edited = first.canonical; edited.title += " edited since backup"
        try db.save(edited)
        var rejected = false
        do { _ = try db.importBackup(repairData) } catch { rejected = true }
        precondition(rejected)
        for pair in repair.pairs {
            let marker = try db.read("retired.task." + pair.duplicate.id.uuidString)
            precondition(marker == nil)
        }
        try db.save(first.canonical)
        let count = try db.importBackup(repairData)
        precondition(count == repair.pairs.count)
        let after = try db.tasks(includeDeleted: true)
        precondition(after.count == before.count - repair.pairs.count)
        for pair in repair.pairs {
            precondition(!after.contains { $0.id == pair.duplicate.id })
            precondition(after.first { $0.id == pair.canonical.id } == pair.merged)
            // The original payload is retained, and stale saves cannot resurrect it.
            let preserved = try db.read("task." + pair.duplicate.id.uuidString)
            precondition(preserved != nil)
            var stale = pair.duplicate; stale.title = "Stale device edit"
            try db.save(stale)
            let stillPreserved = try db.read("task." + pair.duplicate.id.uuidString)
            precondition(preserved == stillPreserved)
        }
        for task in unchanged { precondition(after.contains(task)) }
        let afterNotes = try db.notes(includeHidden: true)
        precondition(Set(beforeNotes.map { $0.id }) == Set(afterNotes.map { $0.id }))
        for note in beforeNotes { precondition(afterNotes.contains(note)) }
        let again = try db.importBackup(repairData); precondition(again == 0)
        // Ordinary backup reimports must not revive duplicate task identities.
        _ = try db.importBackup(snapshot)
        let reopened = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let durable = try reopened.tasks(includeDeleted: true)
        precondition(durable == after)
        let recovery = try decoder.decode(CloudStore.Backup.self, from: reopened.exportBackup())
        precondition(recovery.entries.contains { $0.key.hasPrefix("repair.backup.") && $0.data == repairData })
        print("Repair passed: \(count) exact-identity duplicates retired; unique tasks, notes and merged completions preserved; changed snapshots rejected; repeat imports and stale saves safe; durable reopen verified.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-repair-checks-') as directory:
    path = Path(directory)
    (path/'Checks.swift').write_text('import Foundation\n' + model + store.replace('import Foundation','') + checks)
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(path/'cache'),str(path/'Checks.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks'), *sys.argv[1:]],check=True)
