import Foundation
import CoreData
import CloudKit
import Combine
import CryptoKit

/// One SQLite row per task or preference. Core Data handles the offline change log,
/// CloudKit merges/deletions, and the owner's private and participant's shared stores.
@MainActor final class CloudStore: ObservableObject {
    static let shared = CloudStore()
    static let containerID = "iCloud.com.danturner.HouseHippo"
    let container: NSPersistentCloudKitContainer
    @Published private(set) var status = "Connecting to iCloud…"
    @Published private(set) var lastSync: Date?
    @Published private(set) var revision = 0
    private(set) var loadError: Error?
    private(set) var cloudEnabled: Bool
    private var migrating = false
    private var migrationRows: [String: [NSManagedObject]] = [:]
    private var migrationHome: NSManagedObject?
    private var activeEvents: Set<UUID> = []
    private var activeImports: Set<UUID> = []
    private var remoteRefresh: Task<Void, Never>?
    private var hasPendingRemoteChanges = false
    private var syncErrors: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private var context: NSManagedObjectContext { container.viewContext }
    private var privateStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Private.sqlite" } }
    private var sharedStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Shared.sqlite" } }

    init(directory: URL? = nil, cloudEnabled: Bool = true, defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.sageturner.HouseHippo")) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.cloudEnabled = cloudEnabled
        container = NSPersistentCloudKitContainer(name: "HouseHippo", managedObjectModel: Self.model())
        do {
            let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HouseHippo", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            container.persistentStoreDescriptions = ["Private", "Shared"].map { name in
                let description = NSPersistentStoreDescription(url: base.appendingPathComponent(name + ".sqlite"))
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
                if cloudEnabled {
                    let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerID)
                    options.databaseScope = name == "Private" ? .private : .shared
                    description.cloudKitContainerOptions = options
                }
                return description
            }
            container.loadPersistentStores { [weak self] _, error in
                if let error { self?.loadError = error }
            }
            context.automaticallyMergesChangesFromParent = true
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            context.transactionAuthor = "HouseHippo"
            if let loadError { throw loadError }
            status = cloudEnabled ? "Waiting for iCloud…" : "Local storage · iCloud disabled for this build"
            try migrateLegacyData()
        } catch { loadError = error; status = "Storage unavailable: " + error.localizedDescription }
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // CloudKit metadata/export bookkeeping can also trigger this notification.
                // Batch notifications and let readers publish only actual data differences.
                self.queueRemoteRefresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                guard let self else { return }
                let operation = event.storeIdentifier + "." + String(event.type.rawValue)
                if event.endDate == nil {
                    self.activeEvents.insert(event.identifier)
                    if event.type == .import { self.activeImports.insert(event.identifier) }
                } else {
                    self.activeEvents.remove(event.identifier)
                    if event.type == .import {
                        self.activeImports.remove(event.identifier)
                        self.queueRemoteRefresh()
                    }
                    if let error = event.error {
                        let phase: String
                        switch event.type {
                        case .setup: phase = "Setup"
                        case .import: phase = "Download"
                        case .export: phase = "Upload"
                        @unknown default: phase = "Sync"
                        }
                        self.syncErrors[operation] = phase + ": " + Self.cloudErrorDescription(error)
                    }
                    else if event.succeeded {
                        self.syncErrors.removeValue(forKey: operation)
                        if event.type != .setup { self.lastSync = event.endDate }
                    }
                }
                if !self.syncErrors.isEmpty { self.status = "iCloud needs attention: " + Set(self.syncErrors.values).sorted().joined(separator: "\n") }
                else if !self.activeEvents.isEmpty { self.status = "Syncing with iCloud…" }
                else { self.status = self.lastSync == nil ? "iCloud connected · waiting for first sync" : "Up to date with iCloud" }
            }
        })
    }

    private func queueRemoteRefresh() {
        hasPendingRemoteChanges = true
        remoteRefresh?.cancel()
        remoteRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.activeImports.isEmpty, self.hasPendingRemoteChanges else { return }
            self.hasPendingRemoteChanges = false
            // Core Data merges imported changes; do not refault every object or write records back.
            self.revision += 1
        }
    }

    static func model() -> NSManagedObjectModel {
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = true; return value
        }
        let home = NSEntityDescription(); home.name = "HHHousehold"; home.managedObjectClassName = "NSManagedObject"
        let entry = NSEntityDescription(); entry.name = "HHEntry"; entry.managedObjectClassName = "NSManagedObject"
        let children = NSRelationshipDescription(); children.name = "entries"; children.destinationEntity = entry; children.minCount = 0; children.maxCount = 0; children.isOptional = true; children.deleteRule = .cascadeDeleteRule
        let parent = NSRelationshipDescription(); parent.name = "household"; parent.destinationEntity = home; parent.minCount = 0; parent.maxCount = 1; parent.isOptional = true; parent.deleteRule = .nullifyDeleteRule
        children.inverseRelationship = parent; parent.inverseRelationship = children
        home.properties = [attribute("id", .stringAttributeType), attribute("createdAt", .dateAttributeType), children]
        entry.properties = [attribute("key", .stringAttributeType), attribute("data", .binaryDataAttributeType), attribute("modifiedAt", .dateAttributeType), parent]
        let model = NSManagedObjectModel(); model.entities = [home, entry]; model.versionIdentifiers = ["HouseHippoV1"]; return model
    }

    private func fetch(_ entity: String) throws -> [NSManagedObject] {
        if let loadError { throw loadError }
        return try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
    }
    private func entries(prefix: String) throws -> [NSManagedObject] {
        if let loadError { throw loadError }
        let request = NSFetchRequest<NSManagedObject>(entityName: "HHEntry")
        request.predicate = NSPredicate(format: "key BEGINSWITH %@", prefix)
        request.returnsObjectsAsFaults = false
        return try context.fetch(request)
    }
    private func rows(for key: String) throws -> [NSManagedObject] {
        if migrating { return migrationRows[key] ?? [] }
        if let loadError { throw loadError }
        let request = NSFetchRequest<NSManagedObject>(entityName: "HHEntry")
        request.predicate = NSPredicate(format: "key == %@", key)
        request.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
        return try context.fetch(request)
    }
    private func root() throws -> NSManagedObject {
        if migrating, let migrationHome { return migrationHome }
        let homes = try fetch("HHHousehold").sorted { ($0.value(forKey: "createdAt") as? Date ?? .distantPast) < ($1.value(forKey: "createdAt") as? Date ?? .distantPast) }
        if let shared = homes.first(where: { $0.objectID.persistentStore == sharedStore }), sharedStore != nil { return shared }
        if let existing = homes.first { return existing }
        guard let store = privateStore else { throw CocoaError(.persistentStoreOperation) }
        let home = NSEntityDescription.insertNewObject(forEntityName: "HHHousehold", into: context)
        home.setValue(UUID().uuidString, forKey: "id"); home.setValue(Date(), forKey: "createdAt"); context.assign(home, to: store)
        return home
    }
    func read(_ key: String) throws -> Data? { try rows(for: key).first?.value(forKey: "data") as? Data }
    func put(_ data: Data, key: String) throws {
        // Do not replace a household snapshot: update only the individual entry that changed.
        let existing = try rows(for: key)
        let row: NSManagedObject
        if let first = existing.first { row = first }
        else {
            let home = try root()
            if migrating { migrationHome = home }
            row = NSEntityDescription.insertNewObject(forEntityName: "HHEntry", into: context)
            context.assign(row, to: home.objectID.persistentStore!)
            row.setValue(home, forKey: "household"); row.setValue(key, forKey: "key")
            if migrating { migrationRows[key] = [row] }
        }
        guard row.value(forKey: "data") as? Data != data else { return }
        row.setValue(data, forKey: "data"); row.setValue(Date(), forKey: "modifiedAt")
        if !migrating { try context.save(); revision += 1 }
    }
    func save(_ task: Reminder) throws {
        guard try read("retired.task." + task.id.uuidString) == nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(task), key: "task." + task.id.uuidString)
    }
    func saveAll(_ tasks: [Reminder]) throws {
        try beginBatch()
        defer { endBatch() }
        do { for task in tasks { try save(task) }; try context.save(); revision += 1 }
        catch { context.rollback(); throw error }
    }
    private func beginBatch() throws {
        let rows = try fetch("HHEntry").sorted { ($0.value(forKey: "modifiedAt") as? Date ?? .distantPast) > ($1.value(forKey: "modifiedAt") as? Date ?? .distantPast) }
        migrationRows = Dictionary(grouping: rows, by: { $0.value(forKey: "key") as? String ?? "" })
        migrating = true
    }
    private func endBatch() { migrating = false; migrationRows = [:]; migrationHome = nil }
    func delete(_ task: Reminder) throws {
        var deleted = task
        deleted.deletedAt = Date()
        try save(deleted)
    }
    /// A synced completion is removed locally, never sent to Reminders as a deletion.
    /// Keep only an ID marker so a stale device/import cannot resurrect the task payload.
    func retireCompletedTask(_ task: Reminder) throws {
        guard task.canRetireCompletion, !task.isNotification, task.deletedAt == nil else { return }
        do {
            let markerKey = "retired.task." + task.id.uuidString
            if try rows(for: markerKey).isEmpty {
                let home = try root()
                let marker = NSEntityDescription.insertNewObject(forEntityName: "HHEntry", into: context)
                context.assign(marker, to: home.objectID.persistentStore!)
                marker.setValue(home, forKey: "household")
                marker.setValue(markerKey, forKey: "key")
                marker.setValue(Data([1]), forKey: "data")
                marker.setValue(Date(), forKey: "modifiedAt")
            }
            for row in try rows(for: "task." + task.id.uuidString) { context.delete(row) }
            try context.save()
            revision += 1
        } catch { context.rollback(); throw error }
    }
    func tasks(includeDeleted: Bool = false) throws -> [Reminder] {
        let retired = Set(try entries(prefix: "retired.task.").compactMap { $0.value(forKey: "key") as? String })
        var latest: [String: NSManagedObject] = [:]
        for row in try entries(prefix: "task.") {
            guard let key = row.value(forKey: "key") as? String, key.hasPrefix("task."), !retired.contains("retired." + key) else { continue }
            if let old = latest[key], (old.value(forKey: "modifiedAt") as? Date ?? .distantPast) >= (row.value(forKey: "modifiedAt") as? Date ?? .distantPast) { continue }
            latest[key] = row
        }
        let decoded: [Reminder] = try latest.values.compactMap { row in
            guard let data = row.value(forKey: "data") as? Data else { return nil }
            return try JSONDecoder().decode(Reminder.self, from: data)
        }
        return decoded.filter { includeDeleted || $0.deletedAt == nil }.sorted(by: Reminder.orderedBefore)
    }
    func notes(includeHidden: Bool = false) throws -> [HouseNote] {
        var latest: [String: NSManagedObject] = [:]
        for row in try entries(prefix: "note.") {
            guard let key = row.value(forKey: "key") as? String, key.hasPrefix("note.") else { continue }
            if let existing = latest[key], (existing.value(forKey: "modifiedAt") as? Date ?? .distantPast) >= (row.value(forKey: "modifiedAt") as? Date ?? .distantPast) { continue }
            latest[key] = row
        }
        let result: [HouseNote] = try latest.values.compactMap { row in
            guard let data = row.value(forKey: "data") as? Data else { return nil }
            return try JSONDecoder().decode(HouseNote.self, from: data)
        }
        return result.filter { includeHidden || ($0.archived != true && $0.deletedAt == nil) }.sorted {
            let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    func note(id: UUID) throws -> HouseNote? {
        guard let data = try read("note." + id.uuidString) else { return nil }
        return try JSONDecoder().decode(HouseNote.self, from: data)
    }
    func saveNote(_ note: HouseNote) throws {
        if let existing = try self.note(id: note.id), existing.deletedAt != nil {
            throw NSError(domain: "HouseHippo", code: 3, userInfo: [NSLocalizedDescriptionKey: "This note was deleted. Create a new note to save this text."])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(note), key: "note." + note.id.uuidString)
    }
    static func appleNoteID(sourceID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("Apple Notes\0" + sourceID).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    func importAppleNotes(_ records: [AppleNoteImportRecord]) throws -> AppleNoteImportResult {
        var result = AppleNoteImportResult()
        try beginBatch()
        defer { endBatch() }
        do {
            for record in records {
                guard record.canImport else { result.unreadable += 1; continue }
                let id = Self.appleNoteID(sourceID: record.id)
                // Include deleted/archived notes when checking duplicates: importing again must never resurrect or overwrite them.
                if try note(id: id) != nil { result.alreadyImported += 1; continue }
                var note = HouseNote(id: id, title: record.title, body: record.body)
                note.appleNotesSourceID = record.id
                note.appleNotesOriginalHTML = record.html
                note.appleNotesFolder = record.folder
                note.appleNotesAttachmentCount = record.attachments
                try saveNote(note)
                result.imported += 1
                if record.attachments > 0 { result.withAttachments += 1 }
            }
            if context.hasChanges { try context.save(); revision += 1 }
            return result
        } catch { context.rollback(); throw error }
    }

    func saveNoteFromApple(_ note: HouseNote) throws {
        // Used only by a resolved sync operation; can restore a deletion after the user chose Apple's version.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(note), key: "note." + note.id.uuidString)
    }

    func migrateTaskNote(_ task: inout Reminder) throws {
        if let linked = task.linkedNoteID, let existing = try note(id: linked), existing.deletedAt != nil {
            task.linkedNoteID = nil
            task.notesMigrationVersion = 2
        }
        if task.completed {
            // Repair only untouched notes made from historical completed imports by the old migration.
            // A task completed inside HouseHippo has history and keeps its intentionally linked note.
            if task.sourceID != nil, task.history.isEmpty, task.notesMigrationVersion == 1,
               task.linkedNoteID == task.id, var existing = try note(id: task.id),
               existing.deletedAt == nil, existing.title == task.title, existing.body == task.notes,
               !tasksLinkToNote(task.id, excluding: task.id) {
                existing.archived = true
                existing.sourceTaskID = task.id
                try saveNote(existing)
                task.linkedNoteID = nil
                task.notesMigrationVersion = 2
            }
            return
        }
        guard task.notesMigrationVersion == nil,
              !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Deterministic ID makes migration safe to repeat on another device or after interruption.
        let id = task.id
        if let existing = try note(id: id), existing.deletedAt != nil {
            task.notesMigrationVersion = 2
            return
        }
        if try note(id: id) == nil {
            var imported = HouseNote(id: id, title: task.title, body: task.notes)
            imported.sourceTaskID = id
            try saveNote(imported)
        }
        if task.linkedNoteID == nil { task.linkedNoteID = id }
        task.notesMigrationVersion = 1
    }
    private func tasksLinkToNote(_ noteID: UUID, excluding taskID: UUID) -> Bool {
        // If the database cannot be read, preserve the note rather than hide it.
        guard let tasks = try? tasks() else { return true }
        return tasks.contains { $0.id != taskID && !$0.completed && $0.linkedNoteID == noteID }
    }
    func deleteNote(id: UUID) throws {
        guard var note = try note(id: id), note.deletedAt == nil else { return }
        try beginBatch()
        defer { endBatch() }
        do {
            note.deletedAt = Date()
            note.archived = true
            try saveNote(note) // A retained tombstone prevents old migrations or stale editors from resurrecting it.
            for var task in try tasks() where task.linkedNoteID == id {
                task.linkedNoteID = nil
                task.notesMigrationVersion = 2
                try save(task)
            }
            try context.save()
            revision += 1
        } catch { context.rollback(); throw error }
    }
    func groceries() throws -> [GroceryItem] {
        if let loadError { throw loadError }
        let request = NSFetchRequest<NSManagedObject>(entityName: "HHEntry")
        request.predicate = NSPredicate(format: "key BEGINSWITH %@", "grocery.")
        var latest: [String: NSManagedObject] = [:]
        for row in try context.fetch(request) {
            guard let key = row.value(forKey: "key") as? String, key.hasPrefix("grocery.") else { continue }
            if let old = latest[key], (old.value(forKey: "modifiedAt") as? Date ?? .distantPast) >= (row.value(forKey: "modifiedAt") as? Date ?? .distantPast) { continue }
            latest[key] = row
        }
        let items: [GroceryItem] = try latest.values.compactMap {
            guard let data = $0.value(forKey: "data") as? Data else { return nil }
            return try JSONDecoder().decode(GroceryItem.self, from: data)
        }
        return items.filter { $0.deletedAt == nil }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    func saveGrocery(_ item: GroceryItem) throws {
        let key = "grocery." + item.id.uuidString
        if let data = try read(key), try JSONDecoder().decode(GroceryItem.self, from: data).deletedAt != nil {
            throw NSError(domain: "HouseHippo", code: 4, userInfo: [NSLocalizedDescriptionKey: "This grocery item was deleted. Add a new item to put it back on the list."])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(item), key: key)
    }
    func deleteGrocery(_ item: GroceryItem) throws {
        if let data = try read("grocery." + item.id.uuidString), try JSONDecoder().decode(GroceryItem.self, from: data).deletedAt != nil { return }
        var deleted = item; deleted.deletedAt = Date()
        try saveGrocery(deleted)
    }
    func clearCheckedGroceries() throws {
        let checked = try groceries().filter(\.checked)
        guard !checked.isEmpty else { return }
        try beginBatch()
        defer { endBatch() }
        do {
            let deletedAt = Date()
            for var item in checked {
                item.deletedAt = deletedAt
                try saveGrocery(item)
            }
            try context.save()
            revision += 1
        } catch { context.rollback(); throw error }
    }
    func migrateGroceryText() throws {
        let marker = "househippo.groceries.itemsMigration.v1"
        guard try read(marker) == nil, let data = try read("househippo.groceries"), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        try beginBatch()
        defer { endBatch() }
        do {
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                guard let parsed = GroceryItem.legacyLine(line) else { continue }
                let bytes = Array(SHA256.hash(data: Data(("Grocery legacy\0" + String(index) + "\0" + line).utf8)).prefix(16))
                let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
                if try read("grocery." + id.uuidString) == nil {
                    try saveGrocery(GroceryItem(id: id, name: parsed.name, checked: parsed.checked))
                }
            }
            try put(Data("1".utf8), key: marker)
            try context.save(); revision += 1
        } catch { context.rollback(); throw error }
    }

    func migrateMealDates(calendar: Calendar = .current) throws {
        let rows = try fetch("HHEntry").filter { ($0.value(forKey: "key") as? String)?.hasPrefix("househippo.dinner.") == true }
            .sorted { ($0.value(forKey: "modifiedAt") as? Date ?? .distantPast) > ($1.value(forKey: "modifiedAt") as? Date ?? .distantPast) }
        guard !rows.isEmpty else { return }
        try beginBatch()
        defer { endBatch() }
        do {
            for row in rows {
                guard let oldKey = row.value(forKey: "key") as? String,
                      let data = row.value(forKey: "data") as? Data else { continue }
                let parts = oldKey.split(separator: ".")
                guard parts.count == 4, let epoch = Double(parts[2]), let day = Int(parts[3]), (0..<7).contains(day),
                      let date = calendar.date(byAdding: .day, value: day, to: Date(timeIntervalSince1970: epoch)) else { continue }
                let key = MealWeek.storageKey(for: date, calendar: calendar)
                // Copy by actual date, not by position in the new Saturday week. Preserve newer date-based edits, including blanks.
                if try read(key) == nil { try put(data, key: key) }
            }
            if context.hasChanges { try context.save(); revision += 1 }
        } catch { context.rollback(); throw error }
    }

    func migrateLegacyNotebook() throws {
        let id = UUID(uuidString: "AA904DC3-3500-4B9D-B381-A454AF193F90")!
        guard try note(id: id) == nil,
              let data = try read("househippo.notes"),
              let body = String(data: data, encoding: .utf8),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try saveNote(HouseNote(id: id, title: "Notes", body: body))
    }

    private func migrateLegacyData() throws {
        // Keep the original defaults as a recovery copy; mark only after every row is durable.
        try beginBatch()
        defer { endBatch() }
        guard let store = privateStore else { throw CocoaError(.persistentStoreOperation) }
        var metadata = container.persistentStoreCoordinator.metadata(for: store)
        let domains = [defaults, legacyDefaults].compactMap { $0 }
        for (index, source) in domains.enumerated() {
            let marker = "househippo.sqliteMigration.v1.\(index)"
            guard metadata[marker] as? Bool != true else { continue }
            if let data = source.data(forKey: "reminders") {
                for task in try JSONDecoder().decode([Reminder].self, from: data) {
                    if try read("task." + task.id.uuidString) == nil { try save(task) }
                }
            }
            for key in ["househippo.notes", "househippo.groceries"] {
                if let text = source.string(forKey: key), !text.isEmpty, try read(key) == nil { try put(Data(text.utf8), key: key) }
            }
            if let data = source.data(forKey: "househippo.meals") {
                let weeks = try JSONDecoder().decode([String: [String]].self, from: data)
                for (week, dinners) in weeks {
                    for (day, dinner) in dinners.enumerated() {
                        let key = "househippo.dinner." + week + "." + String(day)
                        if try read(key) == nil { try put(Data(dinner.utf8), key: key) }
                    }
                }
            }
            if context.hasChanges { try context.save() }
            metadata[marker] = true
            container.persistentStoreCoordinator.setMetadata(metadata, for: store)
        }
    }
    struct Backup: Codable {
        let format: String
        let version: Int
        let entries: [Entry]
        struct Entry: Codable {
            let key: String
            let data: Data
            let modifiedAt: Date
        }
    }

    func exportBackup() throws -> Data {
        let rows = try fetch("HHEntry").sorted {
            ($0.value(forKey: "modifiedAt") as? Date ?? .distantPast) > ($1.value(forKey: "modifiedAt") as? Date ?? .distantPast)
        }
        var seen = Set<String>()
        let entries: [Backup.Entry] = rows.compactMap { row in
            guard let key = row.value(forKey: "key") as? String,
                  let data = row.value(forKey: "data") as? Data, seen.insert(key).inserted else { return nil }
            return Backup.Entry(key: key, data: data, modifiedAt: row.value(forKey: "modifiedAt") as? Date ?? .distantPast)
        }
        return try JSONEncoder().encode(Backup(format: "HouseHippo", version: 1, entries: entries))
    }

    /// A reviewed, snapshot-specific reconciliation. Unlike backup import, updates are
    /// allowed only when both task versions still match the inspected backup.
    struct TaskRepair: Codable {
        let format: String
        let version: Int
        let pairs: [Pair]
        struct Pair: Codable {
            let duplicate: Reminder
            let canonical: Reminder
            let merged: Reminder
        }
    }

    private func applyTaskRepair(_ repair: TaskRepair, originalData: Data) throws -> Int {
        func invalid(_ reason: String) -> NSError {
            NSError(domain: "HouseHippo", code: 6, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard repair.format == "HouseHippoTaskRepair", repair.version == 1,
              !repair.pairs.isEmpty,
              Set(repair.pairs.map { $0.duplicate.id }).count == repair.pairs.count,
              Set(repair.pairs.map { $0.canonical.id }).count == repair.pairs.count,
              Set(repair.pairs.map { $0.duplicate.id }).isDisjoint(with: Set(repair.pairs.map { $0.canonical.id })) else {
            throw invalid("This is not a supported task repair file.")
        }
        try beginBatch()
        defer { endBatch() }
        do {
            var pending: [TaskRepair.Pair] = []
            for pair in repair.pairs {
                let sameSource = pair.duplicate.sourceID.map { !$0.isEmpty && $0 == pair.canonical.sourceID } ?? false
                let sameExternal = pair.duplicate.appleReminderExternalID.map { !$0.isEmpty && $0 == pair.canonical.appleReminderExternalID } ?? false
                guard (sameSource || sameExternal), pair.merged.id == pair.canonical.id,
                      pair.duplicate.owner == pair.canonical.owner else {
                    throw invalid("A repair pair does not identify two copies of the same reminder.")
                }
                // Retirement is local to HouseHippo. Never mark the Apple reminder deleted.
                if try read("retired.task." + pair.duplicate.id.uuidString) != nil { continue }
                guard let duplicateData = try read("task." + pair.duplicate.id.uuidString),
                      let canonicalData = try read("task." + pair.canonical.id.uuidString),
                      try JSONDecoder().decode(Reminder.self, from: duplicateData) == pair.duplicate,
                      try JSONDecoder().decode(Reminder.self, from: canonicalData) == pair.canonical,
                      try read("retired.task." + pair.canonical.id.uuidString) == nil else {
                    throw invalid("Tasks have changed since this repair was prepared, or this is a different household. Export a new backup for review; no repair changes were applied.")
                }
                if let noteID = pair.merged.linkedNoteID {
                    guard let note = try note(id: noteID), note.deletedAt == nil else {
                        throw invalid("A note needed by this repair is unavailable. No repair changes were applied.")
                    }
                }
                pending.append(pair)
            }
            guard !pending.isEmpty else { return 0 }
            // Preserve the inspected versions and the repair plan as a recovery record.
            let digest = SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()
            try put(originalData, key: "repair.backup." + digest)
            for pair in pending {
                try save(pair.merged)
                // Keep the duplicate payload and notes for recovery; the marker hides it
                // and blocks stale saves without sending a deletion to Apple Reminders.
                try put(Data([1]), key: "retired.task." + pair.duplicate.id.uuidString)
            }
            try context.save(); revision += 1
            return pending.count
        } catch { context.rollback(); throw error }
    }

    /// Transfer content into fresh stores so CloudKit creates new production metadata.
    /// Existing destination keys always win, including deletions and cleared values.
    func importBackup(_ data: Data) throws -> Int {
        struct Header: Decodable { let format: String }
        if try JSONDecoder().decode(Header.self, from: data).format == "HouseHippoTaskRepair" {
            return try applyTaskRepair(JSONDecoder().decode(TaskRepair.self, from: data), originalData: data)
        }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard backup.format == "HouseHippo", backup.version == 1,
              Set(backup.entries.map(\.key)).count == backup.entries.count,
              backup.entries.allSatisfy({ !$0.key.isEmpty }) else {
            throw NSError(domain: "HouseHippo", code: 5, userInfo: [NSLocalizedDescriptionKey: "This is not a supported HouseHippo backup."])
        }
        try beginBatch()
        defer { endBatch() }
        do {
            var imported = 0
            // Honor source retirement markers regardless of their order in the file.
            let retired = Set(backup.entries.filter { $0.key.hasPrefix("retired.task.") }.map(\.key))
            for entry in backup.entries {
                guard try rows(for: entry.key).isEmpty else { continue }
                if entry.key.hasPrefix("task.") {
                    let hasRetiredMarker = try !rows(for: "retired." + entry.key).isEmpty
                    if retired.contains("retired." + entry.key) || hasRetiredMarker { continue }
                }
                try put(entry.data, key: entry.key)
                migrationRows[entry.key]?.first?.setValue(entry.modifiedAt, forKey: "modifiedAt")
                imported += 1
            }
            if context.hasChanges { try context.save(); revision += 1 }
            return imported
        } catch { context.rollback(); throw error }
    }

    /// CloudKit partial failures wrap the actionable server error inside per-record errors.
    /// Show descriptions only; record IDs, payloads and recipient details stay out of the UI.
    static func cloudErrorDescription(_ error: Error) -> String {
        var details: Set<String> = []
        func collect(_ error: Error, depth: Int) {
            guard depth < 8 else { return }
            let ns = error as NSError
            let batchFailure = ns.domain == CKErrorDomain && ns.code == CKError.batchRequestFailed.rawValue
            if !batchFailure { details.insert(ns.localizedDescription) }
            for key in [NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey, "ServerErrorDescription"] {
                if let text = ns.userInfo[key] as? String, !text.isEmpty { details.insert(text) }
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { collect(underlying, depth: depth + 1) }
            if let partials = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                for child in partials.values { collect(child, depth: depth + 1) }
            }
        }
        collect(error, depth: 0)
        if details.contains(where: { $0.contains("cloudkit.share") && $0.contains("production schema") }) {
            return "Household sharing is unavailable because its iCloud sharing record type has not been deployed to production. The developer must update the CloudKit schema before invitation links can be created. Local changes remain saved on this device; cloud uploads may be waiting."
        }
        let result = details.sorted().joined(separator: "\n")
        return result.isEmpty ? error.localizedDescription : result
    }

    func report(_ error: Error) { status = "iCloud needs attention: " + Self.cloudErrorDescription(error) }
    var householdConnection: String {
        do {
            let homes = try fetch("HHHousehold")
            let joined = homes.filter { $0.objectID.persistentStore == sharedStore }
            if !joined.isEmpty { return "Joined household downloaded · \(joined.count) shared household(s)" }
            return "Using this account's household · no joined household downloaded"
        } catch { return "Household connection unavailable: " + error.localizedDescription }
    }

    func checkAccount() async {
        guard cloudEnabled, loadError == nil else { return }
        do {
            let account = try await CKContainer(identifier: Self.containerID).accountStatus()
            if account != .available { status = "Sign in to iCloud in system settings to sync. Local changes are saved on this device." }
        } catch { status = "iCloud needs attention: " + error.localizedDescription }
    }
    func prepareShare() async throws -> CKShare {
        guard cloudEnabled else { throw NSError(domain: "HouseHippo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run a signed build with the HouseHippo iCloud entitlement to share."]) }
        let home = try root(); try context.save()
        let homeID = home.objectID
        let background = container.newBackgroundContext()
        let persistentContainer = container
        return try await withCheckedThrowingContinuation { continuation in
            background.perform {
                do {
                    if let existing = try persistentContainer.fetchShares(matching: [homeID])[homeID] {
                        continuation.resume(returning: existing)
                        return
                    }
                    let backgroundHome = try background.existingObject(with: homeID)
                    // share() can synchronously wait for Core Data's mirroring queue.
                    // Both the call and its managed object must belong to a background context.
                    persistentContainer.share([backgroundHome], to: nil) { _, share, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let share { continuation.resume(returning: share) }
                        else { continuation.resume(throwing: CocoaError(.persistentStoreOperation)) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        guard let store = sharedStore else { throw CocoaError(.persistentStoreOperation) }
        guard metadata.containerIdentifier == Self.containerID else { throw CocoaError(.validationMissingMandatoryProperty) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.acceptShareInvitations(from: [metadata], into: store) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        status = "Household joined · downloading shared data…"; revision += 1
    }
}
