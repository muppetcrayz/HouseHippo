import XCTest
import CoreData

/// Each test owns a fresh SQLite directory and preferences domain; CloudKit is off.
@MainActor final class StorageTests: XCTestCase {
    private func withStore(_ body: (CloudStore, URL, UserDefaults) throws -> Void) throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HouseHippo-XCTest-" + id)
        let suite = "HouseHippo.XCTest." + id
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = CloudStore(directory: directory, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
        defer {
            for persistentStore in store.container.persistentStoreCoordinator.persistentStores {
                try? store.container.persistentStoreCoordinator.remove(persistentStore)
            }
        }
        XCTAssertNil(store.loadError)
        try body(store, directory, defaults)
    }

    func testDashboardCalendarSelectionsUseHouseholdEntriesWithDeviceLocalMappings() throws {
        try withStore { cloud, _, defaults in
            let firstReader = FakeDashboardCalendarReader()
            let first = DashboardCalendarStore(defaults: defaults, reader: firstReader, household: cloud)
            first.sageID = "apple"; first.danID = "google"
            let data = try XCTUnwrap(cloud.read("dashboard.calendar.sage"))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["label"] as? String, "Personal · iCloud")
            XCTAssertNil(payload["calendarID"], "Local calendar identifiers must not be synced")
            let secondSuite = "HouseHippo.CalendarStorageTests." + UUID().uuidString
            let secondDefaults = UserDefaults(suiteName: secondSuite)!
            defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
            let secondReader = FakeDashboardCalendarReader()
            secondReader.available = [.init(id: "iphone", label: "Personal · iCloud")]
            let second = DashboardCalendarStore(defaults: secondDefaults, reader: secondReader, household: cloud)
            second.refresh()
            XCTAssertEqual(second.sageID, "iphone")
            XCTAssertTrue(second.isUnresolved(.dan))
            XCTAssertEqual(first.sageID, "apple")
            second.sageID = ""
            first.refresh()
            XCTAssertEqual(first.sageID, "")
            XCTAssertEqual(first.danID, "google")
        }
    }

    func testFreshStoreHasNoHouseholdDataOrCloudConnections() throws {
        try withStore { store, _, _ in
            XCTAssertFalse(store.cloudEnabled)
            XCTAssertTrue(try store.tasks().isEmpty)
            XCTAssertTrue(try store.groceries().isEmpty)
            XCTAssertTrue(try store.notes().isEmpty)
            XCTAssertTrue(try store.inventoryCollections().isEmpty)
            XCTAssertTrue(try store.waitingRecords().isEmpty)
            XCTAssertTrue(store.container.persistentStoreDescriptions.allSatisfy { $0.cloudKitContainerOptions == nil })
        }
    }

    func testGroceryEditsPersistAcrossReopen() throws {
        try withStore { store, directory, defaults in
            var item = GroceryItem(name: "Milk")
            try store.saveGrocery(item)
            item.checked = true; item.categoryOverride = .other
            try store.saveGrocery(item)
            let reopened = CloudStore(directory: directory, cloudEnabled: false, defaults: defaults, legacyDefaults: nil)
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(try reopened.groceries(), [item])
        }
    }

    func testClearingCheckedGroceriesPreservesUncheckedAndRejectsStaleSaves() throws {
        try withStore { store, _, _ in
            let checked = GroceryItem(name: "Milk", checked: true)
            let unchecked = GroceryItem(name: "Apples")
            try store.saveGrocery(checked); try store.saveGrocery(unchecked)
            try store.clearCheckedGroceries()
            XCTAssertEqual(try store.groceries(), [unchecked])
            XCTAssertThrowsError(try store.saveGrocery(checked))
            XCTAssertNoThrow(try store.clearCheckedGroceries())
            XCTAssertEqual(try store.groceries(), [unchecked])
        }
    }

    func testGroceryDeletionIsIdempotent() throws {
        try withStore { store, _, _ in
            let item = GroceryItem(name: "Bread")
            try store.saveGrocery(item)
            try store.deleteGrocery(item); try store.deleteGrocery(item)
            XCTAssertTrue(try store.groceries().isEmpty)
            XCTAssertThrowsError(try store.saveGrocery(item))
        }
    }

    func testGroceryMigrationIsIdempotentAndKeepsLaterEdits() throws {
        try withStore { store, _, _ in
            try store.put(Data("- [x] Milk\n- [ ] Apples\n\n".utf8), key: "househippo.groceries")
            try store.migrateGroceryText()
            var items = try store.groceries()
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items.first(where: { $0.name == "Milk" })?.checked, true)
            items[0].name = "Edited"
            try store.saveGrocery(items[0])
            try store.migrateGroceryText()
            XCTAssertEqual(try store.groceries().count, 2)
            XCTAssertTrue(try store.groceries().contains { $0.name == "Edited" })
        }
    }

    func testInventoryImportRollsBackAllRowsOnValidationFailure() throws {
        try withStore { store, _, _ in
            let collection = InventoryCollection(name: "Records", fields: ["Title", "Catalog"])
            XCTAssertThrowsError(try store.createInventory(collection, rows: [["Valid", "0012"], ["Invalid"]]))
            XCTAssertTrue(try store.inventoryCollections().isEmpty)
            XCTAssertTrue(try store.inventoryRecords(for: collection.id).isEmpty)
            try store.createInventory(collection, rows: [["Valid", "0012"]])
            XCTAssertEqual(try store.inventoryCollections().count, 1)
            XCTAssertEqual(try store.inventoryRecords(for: collection.id).first?.values, ["Valid", "0012"])
        }
    }

    func testInventoryRejectsDuplicateFieldsAndStaleSchemaChanges() throws {
        try withStore { store, _, _ in
            XCTAssertThrowsError(try store.saveInventoryCollection(InventoryCollection(name: "Bad", fields: ["Name", "name"])))
            var collection = InventoryCollection(name: "Records", fields: ["Title"])
            try store.createInventory(collection, rows: [["One"]])
            collection.fields = ["Renamed"]
            XCTAssertThrowsError(try store.saveInventoryCollection(collection))
            XCTAssertThrowsError(try store.saveInventoryRecord(InventoryRecord(collectionID: UUID(), values: ["Orphan"])))
        }
    }

    func testWaitingForConversionIsAtomicAndCannotRepeat() throws {
        try withStore { store, _, _ in
            var task = Reminder(title: "  Repair quote  ", message: "", date: Date(), frequency: .anytime)
            task.kind = .task; task.hasDueDate = false; task.taskNote = "Ask about labor"
            try store.save(task)
            try store.convertToWaitingFor(task)
            XCTAssertTrue(try store.tasks().isEmpty)
            let record = try XCTUnwrap(store.waitingRecords().first)
            XCTAssertEqual(record.title, "Repair quote")
            XCTAssertEqual(try store.waitingUpdates(for: record.id).first?.text, "Ask about labor")
            XCTAssertThrowsError(try store.convertToWaitingFor(task))
            XCTAssertEqual(try store.waitingRecords().count, 1)
        }
    }

    func testBackupRoundTripAndRepeatedImportPreserveIndependentRecords() throws {
        try withStore { source, _, _ in
            try source.saveGrocery(GroceryItem(name: "Apples"))
            let note = HouseNote(title: "House", body: "# Repairs\nCall plumber")
            try source.saveNote(note)
            try source.createInventory(InventoryCollection(name: "Records", fields: ["Title"]), rows: [["One"]])
            let backup = try source.exportBackup()
            try withStore { destination, _, _ in
                let existing = GroceryItem(name: "Keep me")
                try destination.saveGrocery(existing)
                _ = try destination.importBackup(backup)
                _ = try destination.importBackup(backup)
                XCTAssertEqual(try destination.groceries().count, 2)
                XCTAssertTrue(try destination.groceries().contains(existing))
                XCTAssertEqual(try destination.note(id: note.id)?.body, note.body)
                XCTAssertEqual(try destination.inventoryCollections().count, 1)
            }
        }
    }

    func testInvalidBackupDoesNotChangeExistingData() throws {
        try withStore { store, _, _ in
            let item = GroceryItem(name: "Keep me")
            try store.saveGrocery(item)
            for invalid in [Data(), Data("{}".utf8), Data("not json".utf8)] {
                XCTAssertThrowsError(try store.importBackup(invalid))
                XCTAssertEqual(try store.groceries(), [item])
            }
        }
    }

    func testNotebookDeletionKeepsTaskNotesIndependent() throws {
        try withStore { store, _, _ in
            var task = Reminder(title: "Repair", message: "", date: Date(), frequency: .anytime)
            task.taskNote = "Task instructions"
            try store.save(task)
            let note = HouseNote(title: "Notebook", body: "Reference")
            try store.saveNote(note)
            try store.resetNotebook()
            XCTAssertTrue(try store.notes().isEmpty)
            let saved = try XCTUnwrap(store.tasks().first)
            XCTAssertEqual(saved.title, task.title)
            XCTAssertEqual(saved.taskNote, "Task instructions")
        }
    }
}
