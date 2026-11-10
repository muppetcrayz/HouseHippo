"""Exercise the app's actual Core Data model, migration and durable writes in isolated stores."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
model = app[app.index('struct Reminder:'):app.index('final class NotificationDelegate')]
model += "\n" + (root / "HouseHippo/GroceryModel.swift").read_text()
model += "\n" + (root / "HouseHippo/Recurrence.swift").read_text()
store = (root / 'HouseHippo/CloudStore.swift').read_text()
checks = r'''
@main struct StorageChecks {
    @MainActor static func main() throws {
        let schemaError = NSError(domain: CKErrorDomain, code: CKError.invalidArguments.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Invalid Arguments", "ServerErrorDescription": "Cannot create new type cloudkit.share in production schema"])
        let partialError = NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Failed to modify some records", CKPartialErrorsByItemIDKey: ["private-record-id": schemaError]])
        let sharingDetail = CloudStore.cloudErrorDescription(partialError)
        precondition(sharingDetail.contains("invitation links"))
        precondition(!sharingDetail.contains("private-record-id"))
        let underlying = NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection unavailable"])
        let wrapped = NSError(domain: "Wrapper", code: 2, userInfo: [NSUnderlyingErrorKey: underlying])
        precondition(CloudStore.cloudErrorDescription(wrapped).contains("Connection unavailable"))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HouseHippo.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        var original = Reminder(title: "Filter", message: "", date: Date(), frequency: .flexible)
        original.notes = "Long notes remain intact"
        defaults.set(try JSONEncoder().encode([original]), forKey: "reminders")
        defaults.set("My notes", forKey: "househippo.notes")
        let db = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        precondition(db.loadError == nil)
        precondition(try db.tasks().count == 1)
        precondition(try db.read("househippo.notes") == Data("My notes".utf8))
        original.title = "Changed offline"
        original.history = [Date()]
        try db.save(original)
        let unchangedRevision = db.revision
        try db.save(original)
        precondition(db.revision == unchangedRevision) // Saving an unchanged task must not enqueue another sync.
        let stableSnapshot = try db.tasks()
        for _ in 0..<20 {
            let reread = try db.tasks()
            precondition(reread == stableSnapshot)
        }
        precondition(!db.container.viewContext.hasChanges) // Reads must not rewrite imported data.
        let second = Reminder(title: "Other task", message: "", date: Date(), frequency: .once)
        try db.save(second)
        precondition(try db.tasks().count == 2)
        // Reopening the same SQLite files must preserve edits and avoid reimporting the old snapshot.
        let reopened = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let tasks = try reopened.tasks()
        precondition(tasks.count == 2)
        precondition(tasks.first { $0.id == original.id }?.title == "Changed offline")
        precondition(tasks.first { $0.id == original.id }?.notes == original.notes)
        try reopened.delete(original)
        let again = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        precondition(try again.tasks().count == 1) // Migration must not resurrect deleted tasks.
        precondition(defaults.data(forKey: "reminders") != nil) // Recovery copy kept.
        let entities = CloudStore.model().entities
        precondition(entities.allSatisfy { $0.uniquenessConstraints.isEmpty })
        precondition(entities.flatMap { $0.attributesByName.values }.allSatisfy { $0.isOptional })
        var importedNoteTask = Reminder(title: "Prayer list", message: "", date: Date(), frequency: .once)
        importedNoteTask.notes = "Original note from Reminders"
        try again.migrateTaskNote(&importedNoteTask)
        precondition(importedNoteTask.taskNote == importedNoteTask.notes && importedNoteTask.linkedNoteID == nil)
        let noSeparateNote = try again.note(id: importedNoteTask.id)
        precondition(noSeparateNote == nil)
        let linkedEdit = HouseNote(title: "Old shared note", body: "Existing linked text\n🦛")
        try again.saveNote(linkedEdit)
        var linkedTaskToMigrate = Reminder(title: "Linked task", message: "", date: Date(), frequency: .once)
        linkedTaskToMigrate.linkedNoteID = linkedEdit.id
        linkedTaskToMigrate.notesMigrationVersion = 1
        try again.migrateTaskNote(&linkedTaskToMigrate)
        precondition(linkedTaskToMigrate.taskNote == linkedEdit.body && linkedTaskToMigrate.linkedNoteID == nil)
        var secondLinkedTask = Reminder(title: "Second task", message: "", date: Date(), frequency: .once)
        secondLinkedTask.linkedNoteID = linkedEdit.id
        try again.migrateTaskNote(&secondLinkedTask)
        linkedTaskToMigrate.taskNote = "Edited inside task"
        try again.save(linkedTaskToMigrate)
        let savedEmbeddedTasks = try again.tasks()
        precondition(savedEmbeddedTasks.contains { $0.id == linkedTaskToMigrate.id && $0.taskNote == "Edited inside task" })
        let independentSource = try again.note(id: linkedEdit.id)
        precondition(independentSource == linkedEdit && secondLinkedTask.taskNote == linkedEdit.body)
        linkedTaskToMigrate.taskNote = ""
        linkedTaskToMigrate.linkedNoteID = linkedEdit.id // Stale legacy link cannot refill cleared text.
        try again.migrateTaskNote(&linkedTaskToMigrate)
        precondition(linkedTaskToMigrate.taskNote == "" && linkedTaskToMigrate.linkedNoteID == nil)
        try again.save(linkedTaskToMigrate)
        let embeddedReload = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let persistedEmbeddedTasks = try embeddedReload.tasks()
        precondition(persistedEmbeddedTasks.contains { $0.id == linkedTaskToMigrate.id && $0.taskNote == "" && $0.linkedNoteID == nil })
        var pendingTask = Reminder(title: "Arrived before note", message: "", date: Date(), frequency: .once)
        let lateNote = HouseNote(title: "Later note", body: "Keep late-arriving text")
        pendingTask.linkedNoteID = lateNote.id
        try again.migrateTaskNote(&pendingTask)
        precondition(pendingTask.taskNote == nil && pendingTask.linkedNoteID == lateNote.id)
        try again.saveNote(lateNote)
        try again.migrateTaskNote(&pendingTask)
        precondition(pendingTask.taskNote == lateNote.body && pendingTask.linkedNoteID == nil)
        var unlinkedTask = Reminder(title: "Previously unlinked", message: "", date: Date(), frequency: .once)
        unlinkedTask.notes = "Recovery text must not reappear"
        unlinkedTask.notesMigrationVersion = 2
        try again.migrateTaskNote(&unlinkedTask)
        precondition(unlinkedTask.taskNote == "" && unlinkedTask.linkedNoteID == nil)
        var completedTask = Reminder(title: "Completed task", message: "", date: Date(), frequency: .once)
        completedTask.completed = true
        completedTask.linkedNoteID = linkedEdit.id
        try again.migrateTaskNote(&completedTask)
        precondition(completedTask.taskNote == linkedEdit.body && completedTask.linkedNoteID == nil)
        var generatedOnly = Reminder(title: "Repeat", message: "", date: Date(), frequency: .once)
        generatedOnly.notes = "\n\nImported repeating reminder. Review its repeat schedule in HouseHippo. Original rule: RRULE FREQ=DAILY;INTERVAL=1"
        generatedOnly.matchImportedRecurrence()
        try again.migrateTaskNote(&generatedOnly)
        precondition(generatedOnly.taskNote == "" && generatedOnly.linkedNoteID == nil)
        let noteToDelete = HouseNote(title: "Delete me", body: "Original content")
        try again.saveNote(noteToDelete)
        var linkedTask = Reminder(title: "Keep task", message: "", date: Date(), frequency: .once)
        linkedTask.linkedNoteID = noteToDelete.id
        try again.save(linkedTask)
        try again.deleteNote(id: noteToDelete.id)
        let afterDeletion = try again.tasks()
        precondition(afterDeletion.contains { $0.id == linkedTask.id && $0.linkedNoteID == nil })
        let afterDeleteNotes = try again.notes()
        precondition(!afterDeleteNotes.contains { $0.id == noteToDelete.id })
        let tombstone = try again.note(id: noteToDelete.id)
        precondition(tombstone?.deletedAt != nil)
        var staleDeletedLink = Reminder(title: "Deleted note", message: "", date: Date(), frequency: .once)
        staleDeletedLink.linkedNoteID = noteToDelete.id
        staleDeletedLink.notes = "Do not resurrect this text"
        try again.migrateTaskNote(&staleDeletedLink)
        precondition(staleDeletedLink.taskNote == "" && staleDeletedLink.linkedNoteID == nil)
        do { try again.saveNote(noteToDelete); fatalError("Stale editor resurrected deleted note") } catch {}
        try again.deleteNote(id: noteToDelete.id) // Idempotent.
        try again.deleteNote(id: linkedEdit.id)
        importedNoteTask.linkedNoteID = linkedEdit.id // Simulate a stale task arriving from another device.
        try again.migrateTaskNote(&importedNoteTask)
        precondition(importedNoteTask.linkedNoteID == nil)
        try again.migrateLegacyNotebook()
        try again.deleteNote(id: UUID(uuidString: "AA904DC3-3500-4B9D-B381-A454AF193F90")!)
        try again.migrateLegacyNotebook()
        let afterLegacyDelete = try again.notes()
        precondition(!afterLegacyDelete.contains { $0.id == UUID(uuidString: "AA904DC3-3500-4B9D-B381-A454AF193F90")! })
        var mealCalendar = Calendar(identifier: .gregorian)
        mealCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let oldSunday = mealCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let nextSaturday = mealCalendar.date(byAdding: .day, value: 6, to: oldSunday)!
        let oldPrefix = "househippo.dinner." + String(Int(oldSunday.timeIntervalSince1970)) + "."
        try again.put(Data("Sunday dinner".utf8), key: oldPrefix + "0")
        try again.put(Data("Saturday dinner".utf8), key: oldPrefix + "6")
        try again.migrateMealDates(calendar: mealCalendar)
        let sundayDinner = try again.read(MealWeek.storageKey(for: oldSunday, calendar: mealCalendar))
        let saturdayDinner = try again.read(MealWeek.storageKey(for: nextSaturday, calendar: mealCalendar))
        precondition(sundayDinner == Data("Sunday dinner".utf8) && saturdayDinner == Data("Saturday dinner".utf8))
        try again.put(Data(), key: MealWeek.storageKey(for: oldSunday, calendar: mealCalendar))
        try again.migrateMealDates(calendar: mealCalendar)
        let intentionallyCleared = try again.read(MealWeek.storageKey(for: oldSunday, calendar: mealCalendar))
        precondition(intentionallyCleared == Data()) // Migration must not resurrect a cleared dinner.
        let saturdayStart = MealWeek.start(containing: oldSunday, calendar: mealCalendar)
        precondition(mealCalendar.component(.weekday, from: saturdayStart) == 7)
        precondition(mealCalendar.component(.day, from: saturdayStart) == 31)
        precondition(MealWeek.start(containing: nextSaturday, calendar: mealCalendar) == nextSaturday)
        let friday = mealCalendar.date(byAdding: .day, value: -1, to: nextSaturday)!
        precondition(MealWeek.start(containing: friday, calendar: mealCalendar) == saturdayStart)
        let afterReopen = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let reopenedDeleted = try afterReopen.note(id: noteToDelete.id)
        precondition(reopenedDeleted?.deletedAt != nil)
        let appleSource = AppleNoteImportRecord(id: "apple-shared-001", title: "Shared shopping", body: "Original text\nQuotes: \"keep\" · 🦛", html: "<div>Original text</div>", folder: "Shared folder", attachments: 0, locked: false)
        let appleAttachment = AppleNoteImportRecord(id: "apple-shared-002", title: "Shared scans", body: "Text only", html: "<div>Text only<img src='cid:scan'></div>", folder: "Shared folder", attachments: 1, locked: false)
        let appleLocked = AppleNoteImportRecord(id: "apple-shared-003", title: "Locked", body: "", html: "", folder: "Shared folder", attachments: 0, locked: true)
        let appleError = AppleNoteImportRecord(id: "apple-shared-004", title: "Unreadable", body: "", html: "", folder: "Shared folder", attachments: 0, locked: false, readError: "Not downloaded")
        let importedApple = try again.importAppleNotes([appleSource, appleAttachment, appleLocked, appleError])
        precondition(importedApple.imported == 2 && importedApple.unreadable == 2 && importedApple.withAttachments == 1)
        let stableAppleID = CloudStore.appleNoteID(sourceID: appleSource.id)
        let appleCopy = try again.note(id: stableAppleID)
        precondition(appleCopy?.body == appleSource.body && appleCopy?.title == appleSource.title)
        precondition(appleCopy?.appleNotesOriginalHTML == appleSource.html)
        var appleEdited = appleCopy!
        appleEdited.body = "Edited in HouseHippo"
        try again.saveNote(appleEdited)
        let duplicateApple = try again.importAppleNotes([appleSource, appleSource])
        precondition(duplicateApple.imported == 0 && duplicateApple.alreadyImported == 2)
        let stillEdited = try again.note(id: stableAppleID)
        precondition(stillEdited?.body == "Edited in HouseHippo")
        try again.deleteNote(id: stableAppleID)
        let deletedApple = try again.importAppleNotes([appleSource])
        precondition(deletedApple.imported == 0 && deletedApple.alreadyImported == 1)
        let sameTitle = AppleNoteImportRecord(id: "apple-shared-other", title: appleSource.title, body: "Different note", html: "", folder: "Other shared folder", attachments: 0, locked: false)
        let anotherApple = try again.importAppleNotes([sameTitle])
        precondition(anotherApple.imported == 1)
        precondition(CloudStore.appleNoteID(sourceID: sameTitle.id) != stableAppleID)
        let foodCases: [(String, GroceryCategory)] = [
            ("2 lb apples", .produce), ("MILK", .dairy), ("Almond milk", .dairy),
            ("eggplant", .produce), ("peanut butter", .pantry), ("chicken broth", .pantry),
            ("frozen peas", .frozen), ("canned tomatoes", .pantry), ("bell pepper", .produce),
            ("black pepper", .pantry), ("cat litter", .household), ("whole wheat bread", .bakery),
            ("salmon", .meat), ("coffee", .drinks), ("mystery item", .other)
        ]
        for (name, expected) in foodCases { precondition(GroceryCategory.suggest(for: name) == expected, name) }
        var food = GroceryItem(name: "milk")
        food.categoryOverride = .pantry
        precondition(food.category == .pantry)
        food.name = "apples"
        precondition(food.category == .pantry)
        food.categoryOverride = nil
        precondition(food.category == .produce)
        try again.put(Data("- [ ] Milk\n- [x] Bread\n\n• 2 lb apples".utf8), key: "househippo.groceries")
        try again.migrateGroceryText()
        let groceries = try again.groceries()
        precondition(groceries.count == 3)
        precondition(groceries.first { $0.name == "Bread" }?.checked == true)
        var milk = groceries.first { $0.name == "Milk" }!
        milk.checked = true
        try again.saveGrocery(milk)
        var apples = groceries.first { $0.name == "2 lb apples" }!
        apples.name = "3 lb apples"
        try again.saveGrocery(apples)
        let independentItems = try again.groceries()
        precondition(independentItems.first { $0.id == milk.id }?.checked == true)
        precondition(independentItems.first { $0.id == apples.id }?.name == "3 lb apples")
        try again.deleteGrocery(milk)
        try again.deleteGrocery(milk)
        try again.migrateGroceryText()
        let afterGroceryDelete = try again.groceries()
        precondition(afterGroceryDelete.count == 2 && !afterGroceryDelete.contains { $0.id == milk.id })
        do { try again.saveGrocery(milk); fatalError("Stale grocery editor resurrected deletion") } catch {}
        let groceryReopen = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let restoredGroceries = try groceryReopen.groceries()
        precondition(restoredGroceries == afterGroceryDelete)
        let oldGroceryText = try groceryReopen.read("househippo.groceries")
        precondition(oldGroceryText != nil)
        try groceryReopen.saveGrocery(GroceryItem(name: "Checked A", checked: true))
        try groceryReopen.saveGrocery(GroceryItem(name: "Checked B", checked: true))
        let keepGrocery = GroceryItem(name: "Keep unchecked")
        try groceryReopen.saveGrocery(keepGrocery)
        let beforeClear = try groceryReopen.groceries()
        let expectedUnchanged = beforeClear.filter { !$0.checked }
        try groceryReopen.clearCheckedGroceries()
        let afterClear = try groceryReopen.groceries()
        precondition(afterClear == expectedUnchanged)
        precondition(afterClear.contains { $0.id == keepGrocery.id })
        let afterClearRevision = groceryReopen.revision
        try groceryReopen.clearCheckedGroceries()
        precondition(groceryReopen.revision == afterClearRevision)
        try groceryReopen.migrateGroceryText()
        let noRecreatedGroceries = try groceryReopen.groceries()
        precondition(noRecreatedGroceries == expectedUnchanged)
        let clearReopen = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let durableClear = try clearReopen.groceries()
        precondition(durableClear == expectedUnchanged)
        var retiredTask = Reminder(title: "Synced completion", message: "", date: Date(), frequency: .once)
        retiredTask.kind = .task
        try clearReopen.save(retiredTask)
        try clearReopen.retireCompletedTask(retiredTask)
        let stillActive = try clearReopen.tasks()
        precondition(stillActive.contains { $0.id == retiredTask.id })
        retiredTask.completed = true
        retiredTask.lastCompleted = Date()
        try clearReopen.save(retiredTask)
        try clearReopen.retireCompletedTask(retiredTask)
        let todayPreserved = try clearReopen.tasks()
        precondition(todayPreserved.contains { $0.id == retiredTask.id })
        retiredTask.lastCompleted = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        try clearReopen.save(retiredTask)
        try clearReopen.retireCompletedTask(retiredTask)
        let removedPayload = try clearReopen.read("task." + retiredTask.id.uuidString)
        precondition(removedPayload == nil)
        var staleEdit = retiredTask
        staleEdit.completed = false
        try clearReopen.save(staleEdit)
        let retiredReopen = CloudStore(directory: base, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        let afterRetirement = try retiredReopen.tasks(includeDeleted: true)
        precondition(!afterRetirement.contains { $0.id == retiredTask.id })
        print("Retirement checks passed: active tasks retained, completed payload removed, stale saves blocked and durable reopen.")
        print("Bulk grocery clear checks passed: all checked removed, unchecked unchanged, empty clear is a no-op, no reimport resurrection and durable reopen.")
        print("Grocery checks passed: deterministic categories, phrase/token precedence, manual overrides, checkbox-text migration, independent item edits, deletion, no resurrection and reopen.")
        print("Apple Notes checks passed: exact text preservation, original HTML metadata, bulk import, unreadable/locked skips, source-ID deduplication, edited copy preservation, deleted copy protection and distinct same-title notes.")
        print("Deletion/meal checks passed: note removal, task unlinking, stale-editor protection, no resurrection, reopen, Saturday week boundaries, DST-safe dinner migration and preserved cleared dinners.")
        print("Task note checks passed: inline migration, independent task text, source preservation, cleared text stays empty, durable reopen, late CloudKit delivery and completed tasks.")
        let transferSuite = "HouseHippo.transfer." + UUID().uuidString
        let transferDefaults = UserDefaults(suiteName: transferSuite)!
        let transferBase = base.appendingPathComponent("transfer")
        defer { transferDefaults.removePersistentDomain(forName: transferSuite) }
        let transfer = CloudStore(directory: transferBase, cloudEnabled: false, defaults: transferDefaults, legacyDefaults: nil)
        let snapshot = try retiredReopen.exportBackup()
        let sourceBackup = try JSONDecoder().decode(CloudStore.Backup.self, from: snapshot)
        let imported = try transfer.importBackup(snapshot)
        precondition(imported > 0)
        for entry in sourceBackup.entries {
            if entry.key.hasPrefix("task."), sourceBackup.entries.contains(where: { $0.key == "retired." + entry.key }) { continue }
            let actual = try transfer.read(entry.key)
            precondition(actual == entry.data)
        }
        try transfer.put(Data("newer destination edit".utf8), key: "househippo.notes")
        let repeated = try transfer.importBackup(snapshot)
        precondition(repeated == 0)
        let transferPreservedEdit = try transfer.read("househippo.notes")
        precondition(transferPreservedEdit == Data("newer destination edit".utf8))
        let reopenedTransfer = CloudStore(directory: transferBase, cloudEnabled: false, defaults: transferDefaults, legacyDefaults: nil)
        let durableEdit = try reopenedTransfer.read("househippo.notes")
        precondition(durableEdit == transferPreservedEdit)
        var rejected = false
        let invalid = CloudStore.Backup(format: "Other app", version: 1, entries: [])
        do { _ = try transfer.importBackup(JSONEncoder().encode(invalid)) } catch { rejected = true }
        precondition(rejected)
        if let path = ProcessInfo.processInfo.environment["HOUSEHIPPO_TRANSFER_FILE"] {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
            let fileBackup = try JSONDecoder().decode(CloudStore.Backup.self, from: fileData)
            let fileSuite = "HouseHippo.file-transfer." + UUID().uuidString
            let fileDefaults = UserDefaults(suiteName: fileSuite)!
            defer { fileDefaults.removePersistentDomain(forName: fileSuite) }
            let destination = CloudStore(directory: base.appendingPathComponent("file-transfer"), cloudEnabled: false, defaults: fileDefaults, legacyDefaults: nil)
            let fileCount = try destination.importBackup(fileData)
            precondition(fileCount == fileBackup.entries.count)
            for entry in fileBackup.entries {
                let actual = try destination.read(entry.key)
                precondition(actual == entry.data)
            }
            print("Verified transfer file: \(fileCount) records imported with identical payloads.")
        }
        print("Backup transfer checks passed: payloads preserved, idempotent import, destination edits kept, retirement markers retained, invalid format rejected and durable reopen.")
        print("Storage checks passed: migration, offline writes, independent tasks, reopen, deletion, recovery copy and CloudKit-compatible schema.")
    }
}
'''
# Swift precondition uses a nonthrowing autoclosure.
checks = checks.replace('precondition(try db.tasks().count == 1)', 'let initial = try db.tasks(); precondition(initial.count == 1)').replace('precondition(try db.read("househippo.notes") == Data("My notes".utf8))', 'let note = try db.read("househippo.notes"); precondition(note == Data("My notes".utf8))').replace('precondition(try db.tasks().count == 2)', 'let saved = try db.tasks(); precondition(saved.count == 2)').replace('precondition(try again.tasks().count == 1)', 'let remaining = try again.tasks(); precondition(remaining.count == 1)')
with tempfile.TemporaryDirectory(prefix='HouseHippo-storage-checks-') as directory:
    path = Path(directory)
    (path/'Checks.swift').write_text('import Foundation\n' + model + store.replace('import Foundation', '') + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path/'cache'), str(path/'Checks.swift'), '-o', str(path/'checks')], check=True)
    subprocess.run([str(path/'checks')], check=True)
