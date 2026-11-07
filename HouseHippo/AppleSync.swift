import SwiftUI
import Combine
import EventKit

@MainActor final class AppleSyncService: ObservableObject {
    static let shared = AppleSyncService()
    @Published var status = "Apple Reminders sync is off"
    @Published var conflicts: [AppleSyncConflict] = []
    @Published var busy = false
    private let cloud = CloudStore.shared
    private let storage = UserDefaults.standard
    let reminders = AppleRemindersAdapter()
    private var timer: Task<Void, Never>?
    private var queued: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var eventObserver: NSObjectProtocol?
    private var stagedConflicts: [AppleSyncConflict] = []
    private var resolutions: [String: AppleSyncPolicy.Action] = [:]
    private var checkpoints: [String: AppleSyncCheckpoint] = [:]
    private var pendingNoteCreates: [String: PendingAppleNoteCreation] = [:]
    private var stateURL: URL?
    private var lastState: Data?
    private var started = false
    private var stateReady = false
    private var again = false
    var deviceID: String {
        if let value = storage.string(forKey: "househippo.appleSync.device") { return value }
        let value = UUID().uuidString; storage.set(value, forKey: "househippo.appleSync.device"); return value
    }
    private struct State: Codable { var checkpoints: [String: AppleSyncCheckpoint]; var pendingNoteCreates: [String: PendingAppleNoteCreation] }
    func settings() -> AppleSyncSettings {
        guard let data = try? cloud.read("apple.sync.settings"), let value = try? JSONDecoder().decode(AppleSyncSettings.self, from: data) else { return AppleSyncSettings() }
        return value
    }
    func saveSettings(_ settings: AppleSyncSettings) throws {
        try cloud.put(appleSyncData(settings), key: "apple.sync.settings")
        request()
    }
    #if os(macOS)
    func useThisMac() throws {
        start()
        guard stateReady, !busy else { throw failure("Wait for Apple sync to finish starting or running, then try again.") }
        var config = settings()
        config.deviceID = deviceID
        // Keep this installation's checkpoints. Without a baseline, existing items
        // go through the normal initial-conflict review rather than overwriting either app.
        try saveSettings(config)
        status = config.enabled ? "This Mac now manages Apple Reminders sync" : "This Mac is selected · Apple Reminders sync is off"
    }
    #endif
    func start() {
        guard !started else { return }; started = true
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HouseHippo/AppleSync", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let url = base.appendingPathComponent(deviceID + ".json"); stateURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let saved = try JSONDecoder().decode(State.self, from: data)
                checkpoints = saved.checkpoints; pendingNoteCreates = saved.pendingNoteCreates; lastState = data
            }
        } catch { status = "Apple sync checkpoint could not be read: " + error.localizedDescription; return }
        stateReady = true
        observer = cloud.$revision.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] _ in Task { @MainActor in self?.request() } }
        eventObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: reminders.events, queue: .main) { [weak self] _ in Task { @MainActor in self?.request() } }
        #if os(macOS)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.request()
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            }
        }
        #else
        status = settings().enabled ? "Apple Reminders sync runs through your Mac while HouseHippo is open there" : "Apple Reminders sync is off"
        #endif
    }
    func request() {
        #if os(macOS)
        guard started else { start(); return }
        guard stateReady else { return }
        if busy { again = true; return }
        queued?.cancel()
        queued = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.run()
        }
        #else
        status = settings().enabled ? "Apple Reminders sync runs through your Mac while HouseHippo is open there" : "Apple Reminders sync is off"
        #endif
    }
    func resolve(_ conflict: AppleSyncConflict, using action: AppleSyncPolicy.Action) { resolutions[conflict.id] = action; request() }
    private func persist() throws {
        guard let stateURL else { throw failure("Sync checkpoint storage is unavailable") }
        let data = try appleSyncData(State(checkpoints: checkpoints, pendingNoteCreates: pendingNoteCreates))
        guard data != lastState else { return }
        try data.write(to: stateURL, options: .atomic); lastState = data
    }
    private func conflict(_ id: String, title: String, message: String, local: String, remote: String, canChoose: Bool = true, allowPush: Bool = true, allowPull: Bool = true, localAction: String? = nil, remoteAction: String? = nil) {
        stagedConflicts.append(AppleSyncConflict(id: id, title: title, explanation: message, local: local, remote: remote, canChoose: canChoose, allowPush: allowPush, allowPull: allowPull, localActionTitle: localAction, remoteActionTitle: remoteAction))
    }
    private struct ResolutionBackup: Codable { var item: String; var date: Date; var local: Data?; var remote: Data? }
    private func decision(_ key: String, base: Data?, local: Data?, remote: Data?) throws -> AppleSyncPolicy.Action {
        if let resolution = resolutions.removeValue(forKey: key) {
            try cloud.put(appleSyncData(ResolutionBackup(item: key, date: Date(), local: local, remote: remote)), key: "apple.sync.backup." + UUID().uuidString)
            return resolution
        }
        return AppleSyncPolicy.action(base: base, local: local, remote: remote)
    }
    private func confirmedMissing(_ checkpoint: inout AppleSyncCheckpoint) -> Bool {
        if checkpoint.missingSince == nil { checkpoint.missingSince = Date(); return false }
        return Date().timeIntervalSince(checkpoint.missingSince!) >= 60
    }
    private func requireCurrentSettings(_ expected: AppleSyncSettings) throws {
        let current = settings()
        guard current.enabled, current.deviceID == deviceID,
              try appleSyncData(current) == appleSyncData(expected) else { throw failure("Sync settings changed; further operations stopped") }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "HouseHippo.AppleSync", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
    #if os(macOS)
    private func run() async {
        let config = settings()
        guard config.enabled else { status = "Apple Reminders sync is off"; return }
        guard config.deviceID == deviceID else { status = "Apple Reminders sync belongs to a previous installation or another Mac. Choose Use this Mac in Apple Reminders sync settings."; return }
        guard !busy else { again = true; return }
        busy = true; stagedConflicts = []; status = "Syncing with Apple Reminders…"
        defer {
            if conflicts != stagedConflicts { conflicts = stagedConflicts }
            busy = false
            if again { again = false; request() }
        }
        var errors: [String] = []
        do { try await syncReminders(config) } catch { errors.append("Reminders: " + error.localizedDescription) }
        do { try persist() } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { status = errors.joined(separator: "\n") }
        else if !stagedConflicts.isEmpty { status = "\(stagedConflicts.count) Apple sync item(s) pending or needing review" }
        else { status = "Apple Reminders up to date · " + Date().formatted(date: .omitted, time: .shortened) }
    }

    private func syncReminders(_ config: AppleSyncSettings) async throws {
        let all = try cloud.tasks(includeDeleted: true).filter { !$0.isNotification }
        let participating = all
        let known = checkpoints.filter { $0.key.hasPrefix("task.") }.map(\.value) + participating.compactMap { task in task.sourceID.map { AppleSyncCheckpoint(sourceID: $0, externalID: task.appleReminderExternalID) } }
        let snapshot = try await reminders.snapshot(settings: config, known: known)
        var bound: Set<String> = []
        let freshTasks = try cloud.tasks(includeDeleted: true)
        for var task in freshTasks where task.syncsWithAppleReminders {
            try requireCurrentSettings(config)
            let key = "task." + task.id.uuidString
            var checkpoint = checkpoints[key]
            let sourceID = checkpoint?.sourceID ?? task.sourceID
            let external = checkpoint?.externalID ?? task.appleReminderExternalID
            let marker = "househippo://task/" + task.id.uuidString
            let candidates = snapshot.filter {
                $0.calendarItemIdentifier == sourceID || (external != nil && $0.calendarItemExternalIdentifier == external) || $0.url?.absoluteString == marker
            }
            let active = candidates.filter { !$0.isCompleted }
            if active.count > 1 { conflict(key, title: task.title, message: "More than one Apple reminder matches this task. No duplicate was created.", local: task.title, remote: "Multiple matches", canChoose: false); continue }
            let remote = active.first ?? candidates.first { candidate in
                if let sourceID { return candidate.calendarItemIdentifier == sourceID }
                return candidate.url?.absoluteString == marker
            }
            if let remote {
                guard config.calendarIDs.contains(remote.calendar.calendarIdentifier) else {
                    var paused = checkpoint ?? AppleSyncCheckpoint(sourceID: remote.calendarItemIdentifier, externalID: remote.calendarItemExternalIdentifier)
                    paused.outOfScope = true
                    checkpoints[key] = paused; try persist(); continue
                }
                checkpoint?.outOfScope = false
                bound.insert(remote.calendarItemIdentifier)
                task.appleReminderCalendarID = task.appleReminderCalendarID ?? remote.calendar.calendarIdentifier
                task.appleReminderExternalID = remote.calendarItemExternalIdentifier
            }
            if remote == nil {
                if checkpoint?.outOfScope == true { continue }
                if let oldList = task.appleReminderCalendarID, !config.calendarIDs.contains(oldList) { continue }
            }
            let localValue: SyncedTaskValue?
            do { localValue = task.deletedAt == nil ? try reminders.localValue(task, settings: config) : nil }
            catch { conflict(key, title: task.title, message: error.localizedDescription, local: task.summary, remote: "Schedule not changed", canChoose: false); continue }
            let remoteValue: SyncedTaskValue?
            do { remoteValue = try remote.map { try reminders.value($0) } }
            catch { conflict(key, title: task.title, message: error.localizedDescription, local: task.summary, remote: "Apple repeat needs review", canChoose: false); continue }
            // Historical completed imports may be removed only after checking the actual
            // Apple record. Never create a completed backfill or discard an unsynced edit.
            if task.canRetireCompletion, task.deletedAt == nil, let localValue,
               remoteValue == localValue, localValue.rule == nil, checkpoint?.pendingCompletion == nil {
                try cloud.retireCompletedTask(task)
                checkpoints.removeValue(forKey: key); try persist(); continue
            }
            if checkpoint == nil && task.completed && task.history.isEmpty && task.deletedAt == nil { continue }
            if sourceID == nil && remote == nil {
                guard let localValue else { continue }
                let created = try reminders.create(taskID: task.id, desired: localValue)
                task.sourceID = created.calendarItemIdentifier; task.appleReminderExternalID = created.calendarItemExternalIdentifier; task.appleReminderCalendarID = created.calendar.calendarIdentifier
                try cloud.save(task)
                checkpoints[key] = AppleSyncCheckpoint(sourceID: created.calendarItemIdentifier, externalID: created.calendarItemExternalIdentifier, base: try appleSyncData(try reminders.value(created)), lastCompletion: task.lastCompleted)
                bound.insert(created.calendarItemIdentifier); try persist()
                if task.canRetireCompletion, localValue.rule == nil, try reminders.value(created) == localValue {
                    try cloud.retireCompletedTask(task)
                    checkpoints.removeValue(forKey: key); try persist()
                }
                continue
            }
            if checkpoint == nil { checkpoint = AppleSyncCheckpoint(sourceID: remote?.calendarItemIdentifier ?? sourceID!, externalID: external) }
            let localData = try localValue.map(appleSyncData)
            let remoteData = try remoteValue.map(appleSyncData)
            if remote == nil && localData != nil {
                if !confirmedMissing(&checkpoint!) { checkpoints[key] = checkpoint; try persist(); continue }
            } else { checkpoint!.missingSince = nil }
            // A repeating completion is an acknowledged event, not merely a due-date edit.
            if let pending = checkpoint!.pendingCompletion, let remote, let remoteValue, let localValue {
                if remoteValue == localValue && !remote.isCompleted {
                    checkpoint!.pendingCompletion = nil; checkpoint!.lastCompletion = pending; checkpoint!.base = localData
                } else if remote.isCompleted {
                    conflict(key, title: task.title, message: "Waiting for Apple Reminders to expose the next repeating occurrence.", local: task.summary, remote: "Completed occurrence", canChoose: false)
                    checkpoints[key] = checkpoint; try persist(); continue
                } else if remote.calendarItemIdentifier != checkpoint!.sourceID {
                    _ = try reminders.update(remote, expected: remoteValue, desired: localValue)
                    checkpoint!.pendingCompletion = nil; checkpoint!.lastCompletion = pending; checkpoint!.base = localData
                } else if remoteData == checkpoint!.base {
                    try reminders.complete(remote, expected: remoteValue, date: pending)
                    checkpoints[key] = checkpoint; try persist(); again = true; continue
                } else {
                    conflict(key, title: task.title, message: "A repeating task changed while its completion was being synced.", local: task.summary, remote: remoteValue.description, canChoose: false)
                    checkpoints[key] = checkpoint; try persist(); continue
                }
            }
            let action = try decision(key, base: checkpoint!.base, local: localData, remote: remoteData)
            switch action {
            case .conflict:
                conflict(key, title: task.title, message: checkpoint!.base == nil ? "Initial task versions differ. Choose which to keep." : "Both apps changed this task since the last sync.", local: localValue.map { $0.description + "\nList: " + task.list } ?? "Deleted in HouseHippo", remote: remoteValue.map { $0.description + "\nList: " + (remote?.calendar.title ?? "Reminders") } ?? "Deleted or unavailable in Reminders")
            case .push:
                if let remote, let remoteValue, let localValue {
                    if localValue.rule != nil, !localValue.completed, let completion = task.lastCompleted,
                       completion > (checkpoint!.lastCompletion ?? .distantPast) {
                        checkpoint!.pendingCompletion = completion; checkpoints[key] = checkpoint; try persist()
                        try reminders.complete(remote, expected: remoteValue, date: completion)
                        again = true; continue
                    }
                    let updated = try reminders.update(remote, expected: remoteValue, desired: localValue, completionDate: task.lastCompleted)
                    checkpoint!.sourceID = updated.calendarItemIdentifier; checkpoint!.externalID = updated.calendarItemExternalIdentifier
                    checkpoint!.base = try appleSyncData(try reminders.value(updated)); checkpoint!.lastCompletion = task.lastCompleted
                } else if let remote, let remoteValue {
                    try reminders.delete(remote, expected: remoteValue); checkpoint!.base = nil
                } else if let localValue {
                    let created = try reminders.create(taskID: task.id, desired: localValue)
                    checkpoint!.sourceID = created.calendarItemIdentifier; checkpoint!.externalID = created.calendarItemExternalIdentifier
                    checkpoint!.base = try appleSyncData(try reminders.value(created))
                }
            case .pull:
                if let remote, let remoteValue {
                    let owner = config.calendarOwners[remote.calendar.calendarIdentifier].flatMap(Reminder.Owner.init(rawValue:)) ?? task.owner
                    if let previous = snapshot.first(where: { $0.calendarItemIdentifier == checkpoint!.sourceID }), let date = previous.completionDate, date != task.lastCompleted {
                        task.lastCompleted = date; if !task.history.contains(date) { task.history.append(date) }
                    }
                    reminders.apply(remoteValue, to: &task, source: remote, owner: owner)
                    try cloud.save(task); checkpoint!.base = remoteData; checkpoint!.lastCompletion = task.lastCompleted
                } else { try cloud.delete(task); checkpoint!.base = nil }
            case .acknowledge: checkpoint!.base = localData; checkpoint!.lastCompletion = task.lastCompleted
            case .missing: break
            }
            if let remote {
                checkpoint!.sourceID = remote.calendarItemIdentifier; checkpoint!.externalID = remote.calendarItemExternalIdentifier
                task.sourceID = remote.calendarItemIdentifier
                task.appleReminderExternalID = remote.calendarItemExternalIdentifier
                // Save identity only if this operation did not delete the local task.
                if action != .pull || remoteValue != nil { try cloud.save(task) }
            }
            checkpoints[key] = checkpoint; try persist()
            if action != .conflict, task.canRetireCompletion, task.deletedAt == nil,
               checkpoint?.pendingCompletion == nil,
               let base = checkpoint?.base,
               let confirmed = try? JSONDecoder().decode(SyncedTaskValue.self, from: base),
               confirmed.completed, confirmed.rule == nil {
                try cloud.retireCompletedTask(task)
                checkpoints.removeValue(forKey: key); try persist()
            }
        }
        let current = try cloud.tasks(includeDeleted: true)
        for remote in snapshot where !remote.isCompleted && config.calendarIDs.contains(remote.calendar.calendarIdentifier) && !bound.contains(remote.calendarItemIdentifier) {
            try requireCurrentSettings(config)
            if current.contains(where: { $0.sourceID == remote.calendarItemIdentifier || ($0.appleReminderExternalID != nil && $0.appleReminderExternalID == remote.calendarItemExternalIdentifier) || remote.url?.absoluteString == "househippo://task/" + $0.id.uuidString }) { continue }
            let value: SyncedTaskValue
            do { value = try reminders.value(remote) }
            catch {
                conflict("unsupported-task." + remote.calendarItemIdentifier, title: remote.title ?? "Apple task", message: error.localizedDescription, local: "Not imported automatically", remote: "Unsupported Apple repeat schedule", canChoose: false)
                continue
            }
            if value.rule != nil {
                let possible = current.filter { $0.syncsWithAppleReminders && $0.sourceID != nil && $0.title == value.title && $0.list == AppleRemindersAdapter.listName(remote.calendar.title) && !$0.isUnscheduled && $0.frequency != .once }
                if !possible.isEmpty {
                    let choiceID = "successor." + remote.calendarItemIdentifier
                    if resolutions[choiceID] == .pull, possible.count == 1 {
                        resolutions.removeValue(forKey: choiceID)
                        var existing = possible[0]
                        let owner = config.calendarOwners[remote.calendar.calendarIdentifier].flatMap(Reminder.Owner.init(rawValue:)) ?? existing.owner
                        reminders.apply(value, to: &existing, source: remote, owner: owner)
                        try cloud.save(existing)
                        checkpoints["task." + existing.id.uuidString] = AppleSyncCheckpoint(sourceID: remote.calendarItemIdentifier, externalID: remote.calendarItemExternalIdentifier, base: try appleSyncData(value), lastCompletion: existing.lastCompleted)
                        try persist(); continue
                    } else if resolutions[choiceID] == .push {
                        resolutions.removeValue(forKey: choiceID) // Explicit request to import a genuinely separate matching task.
                    } else {
                        conflict(choiceID, title: value.title, message: "This may be a new occurrence of an existing repeating task. Choose whether to connect it or import a separate task.", local: possible.map(\.summary).joined(separator: "\n"), remote: value.description, allowPull: possible.count == 1, localAction: "Import as separate task", remoteAction: "Use as next occurrence")
                        continue
                    }
                }
            }
            let importedID = CloudStore.appleNoteID(sourceID: "reminder:" + (remote.calendarItemExternalIdentifier ?? remote.calendarItemIdentifier))
            // Reopening a completed Apple reminder starts a fresh local task identity.
            let id = try cloud.read("retired.task." + importedID.uuidString) == nil ? importedID : UUID()
            var task = Reminder(id: id, title: value.title, message: "", date: value.date ?? .distantPast, frequency: .once)
            let owner = config.calendarOwners[remote.calendar.calendarIdentifier].flatMap(Reminder.Owner.init(rawValue:)) ?? .shared
            reminders.apply(value, to: &task, source: remote, owner: owner)
            try cloud.save(task)
            checkpoints["task." + task.id.uuidString] = AppleSyncCheckpoint(sourceID: remote.calendarItemIdentifier, externalID: remote.calendarItemExternalIdentifier, base: try appleSyncData(value), lastCompletion: task.lastCompleted)
            try persist()
        }
    }
    #endif
}

struct AppleSyncControls: View {
    @ObservedObject private var sync = AppleSyncService.shared
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
            Button("Apple Reminders sync…") { showing = true }
        }.sheet(isPresented: $showing) { AppleSyncSettingsView().frame(minWidth: 400, minHeight: 520) }
    }
}

struct AppleSyncSettingsView: View {
    @ObservedObject private var sync = AppleSyncService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var config = AppleSyncSettings()
    @State private var calendars: [EKCalendar] = []
    @State private var loading = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section {
                    Text("Two-way sync runs on this Mac while HouseHippo is open. Additions, edits, task completion and deletions sync both ways. Task notes stay in HouseHippo and sync through iCloud between your devices.").font(.callout)
                    Text("Flexible tasks stay in HouseHippo, including their edits and completions. They are not sent back to Apple Reminders. Existing Apple copies are left unchanged.").font(.caption).foregroundStyle(.secondary)
                    Text("Only lists available to this Mac's Apple Account can sync. Assign each list to Sage, Dan or Shared; tasks are never sent to another person's list.").font(.caption).foregroundStyle(.secondary)
                    Button(loading ? "Loading…" : "Choose Reminders lists") {
                        loading = true
                        Task {
                            do {
                                try await sync.reminders.authorize()
                                calendars = sync.reminders.calendars()
                                for calendar in calendars where config.calendarOwners[calendar.calendarIdentifier] == nil {
                                    let personal = calendar.title.lowercased().contains("personal")
                                    config.calendarOwners[calendar.calendarIdentifier] = personal ? (UserDefaults.standard.string(forKey: "househippo.person") ?? Reminder.Owner.me.rawValue) : Reminder.Owner.shared.rawValue
                                }
                            } catch { issue = error.localizedDescription }
                            loading = false
                        }
                    }.disabled(loading)
                    if let issue { Text(issue).foregroundStyle(.red) }
                }
                if !calendars.isEmpty {
                    Section("Reminders lists to sync") {
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(calendar.title + " · " + calendar.source.title, isOn: Binding(get: { config.calendarIDs.contains(calendar.calendarIdentifier) }, set: { selected in
                                config.calendarIDs.removeAll { $0 == calendar.calendarIdentifier }
                                if selected { config.calendarIDs.append(calendar.calendarIdentifier) }
                            }))
                            if config.calendarIDs.contains(calendar.calendarIdentifier) {
                                Picker("Tasks belong to", selection: Binding(get: { config.calendarOwners[calendar.calendarIdentifier] ?? Reminder.Owner.shared.rawValue }, set: { config.calendarOwners[calendar.calendarIdentifier] = $0 })) {
                                    ForEach(Reminder.Owner.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                                }
                            }
                        }
                        Picker("Default list for new tasks", selection: $config.defaultCalendarID) {
                            Text("Choose a list").tag("")
                            ForEach(calendars.filter { config.calendarIDs.contains($0.calendarIdentifier) }, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                        }
                    }
                }
                Section {
                    Toggle("Enable two-way Apple sync", isOn: $config.enabled)
                    Text(sync.status).font(.caption)
                    if !config.deviceID.isEmpty && config.deviceID != sync.deviceID {
                        Text("Apple Reminders sync is assigned to a previous installation or another Mac. If this Mac should handle it now, select Use this Mac. Keep the previous installation closed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Use this Mac") {
                            do { try sync.useThisMac(); config = sync.settings(); issue = nil }
                            catch { issue = error.localizedDescription }
                        }.disabled(sync.busy)
                    }
                    Button("Sync now") { sync.request() }.disabled(sync.busy || config.deviceID != sync.deviceID)
                }
                #else
                Section { Text("Configure Apple Reminders sync on your Mac. HouseHippo changes made here reach that Mac through iCloud; keep the Mac app open for the Apple-app bridge to run.") }
                #endif
                if !sync.conflicts.isEmpty {
                    Section("Sync items needing attention") {
                        ForEach(sync.conflicts) { conflict in
                            DisclosureGroup(conflict.title) {
                                Text(conflict.explanation)
                                Text("HouseHippo").font(.headline); Text(conflict.local).textSelection(.enabled)
                                Text("Apple app").font(.headline); Text(conflict.remote).textSelection(.enabled)
                                if conflict.canChoose {
                                    if conflict.allowPush { Button(conflict.localActionTitle ?? "Use HouseHippo version") { sync.resolve(conflict, using: .push) } }
                                    if conflict.allowPull { Button(conflict.remoteActionTitle ?? "Use Apple version") { sync.resolve(conflict, using: .pull) } }
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle("Apple Reminders sync")
            .onAppear { config = sync.settings(); sync.start() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                #if os(macOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            if config.enabled {
                                guard config.calendarIDs.contains(config.defaultCalendarID) else { issue = "Choose Reminders lists and a default task list first."; return }
                                guard config.deviceID.isEmpty || config.deviceID == sync.deviceID else { issue = "Select Use this Mac to move Apple Reminders sync from the previous installation or Mac, then save."; return }
                                config.deviceID = sync.deviceID
                            }
                            try sync.saveSettings(config); dismiss()
                        } catch { issue = error.localizedDescription }
                    }
                }
                #endif
            }
        }
    }
}
