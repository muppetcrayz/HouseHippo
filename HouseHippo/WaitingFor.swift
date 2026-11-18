import SwiftUI

struct WaitingForView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var records: [WaitingRecord] = []
    @State private var adding = false
    @State private var issue: String?
    var body: some View {
        List {
            if records.isEmpty {
                HippoEmptyState(title: "What are you waiting for?", icon: "clock", message: "Add a record, then keep dated updates as things happen.")
            }
            ForEach(records) { record in
                NavigationLink { WaitingRecordView(record: record) } label: { Text(record.title) }
            }
        }
        .hippoPage()
        .navigationTitle("Waiting For")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add record", systemImage: "plus") { adding = true } } }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(isPresented: $adding) { WaitingRecordCreator().frame(minWidth: 340, minHeight: 240) }
        .alert("Waiting For", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func reload() {
        do { records = try cloud.waitingRecords() } catch { issue = error.localizedDescription }
    }
}

private struct WaitingRecordCreator: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                HippoField("Waiting for", text: $title, prompt: "e.g. A call back from Doug", autofocus: true)
            }.hippoForm()
            .navigationTitle("Add Waiting For record")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not create record", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try CloudStore.shared.saveWaitingRecord(WaitingRecord(title: value)); dismiss() }
        catch { issue = error.localizedDescription }
    }
}

private struct WaitingRecordView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var record: WaitingRecord
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var taskDraft: Reminder?
    @State private var updates: [WaitingUpdate] = []
    @State private var editing: WaitingUpdate?
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var editingTitle = false
    @State private var title = ""
    var body: some View {
        List {
            Section("Updates · newest first") {
                if updates.isEmpty { Text("No updates yet.").foregroundStyle(.secondary) }
                ForEach(updates) { update in
                    VStack(alignment: .leading, spacing: 8) {
                    Button { editing = update } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(update.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(update.text).foregroundStyle(.primary)
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button("Create flexible task", systemImage: "plus.circle") {
                        taskDraft = update.flexibleTask(recordTitle: record.title, owner: Reminder.Owner(rawValue: person) ?? .me)
                    }.font(.callout).buttonStyle(.borderless)
                    }
                }
            }
        }
        .hippoPage()
        .navigationTitle(record.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add update", systemImage: "plus") { editing = WaitingUpdate(recordID: record.id, text: "") }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Edit title") { title = record.title; editingTitle = true }
                    Button("Delete record", role: .destructive) { confirmingDelete = true }
                } label: { Label("Record options", systemImage: "ellipsis.circle") }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { WaitingUpdateEditor(update: $0).frame(minWidth: 320, minHeight: 350) }
        .sheet(item: $taskDraft) { WaitingFlexibleTaskEditor(task: $0).frame(minWidth: 320, minHeight: 350) }
        .alert("Edit title", isPresented: $editingTitle) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                var changed = record; changed.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !changed.title.isEmpty else { return }
                do { try cloud.saveWaitingRecord(changed); record = changed } catch { issue = error.localizedDescription }
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete this record and its updates?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete record", role: .destructive) {
                var deleted = record; deleted.deletedAt = Date()
                do { try cloud.saveWaitingRecord(deleted); dismiss() } catch { issue = error.localizedDescription }
            }
        }
        .alert("Waiting For", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func reload() {
        do {
            guard let current = try cloud.waitingRecords().first(where: { $0.id == record.id }) else { dismiss(); return }
            record = current
            updates = try cloud.waitingUpdates(for: record.id)
        } catch { issue = error.localizedDescription }
    }
}

private struct WaitingUpdateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var update: WaitingUpdate
    @State private var issue: String?
    @State private var confirmingDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Update") {
                    HippoTextArea(label: "What happened?", text: $update.text)
                    DatePicker("Date and time", selection: $update.date, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Button("Delete update", role: .destructive) { confirmingDelete = true }
                }
            }.hippoForm()
            .navigationTitle("Waiting For update")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this update?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete update", role: .destructive) { update.deletedAt = Date(); save() }
            }
            .alert("Could not save update", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        update.text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.saveWaitingUpdate(update); dismiss() } catch { issue = error.localizedDescription }
    }
}

private struct WaitingFlexibleTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var task: Reminder
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Flexible task") {
                    HippoField("Task title", text: $task.title, prompt: "What needs doing?")
                    Picker("For", selection: $task.owner) {
                        ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("No due date. This will appear with your flexible tasks.").font(.caption).foregroundStyle(.secondary)
                }
                TaskNoteSection(reminder: $task)
            }.hippoForm()
            .navigationTitle("Create flexible task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        task.list = task.owner == .shared ? "One-off general tasks" : "One-off personal tasks"
                        do {
                            try CloudStore.shared.save(task)
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }.disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not create task", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
}

struct BorrowingLendingView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var items: [BorrowedItem] = []
    @State private var editing: BorrowedItem?
    @State private var showReturned = false
    @State private var issue: String?
    private var people: [String] { Array(Set(items.map(\.person))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var body: some View {
        List {
            Section {
                Toggle("Show returned items", isOn: $showReturned)
            }
            if items.isEmpty {
                HippoEmptyState(title: "Keep track of who has what", icon: "arrow.left.arrow.right", message: "Add an item and a person. Check it off when it’s returned.")
            }
            ForEach(people, id: \.self) { person in
                let visible = items.filter { $0.person == person && (showReturned || $0.returnedAt == nil) }
                if !visible.isEmpty {
                    Section(person) {
                        ForEach(visible) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    var changed = item
                                    changed.returnedAt = item.returnedAt == nil ? Date() : nil
                                    do { try cloud.saveBorrowedItem(changed); reload() } catch { issue = error.localizedDescription }
                                } label: {
                                    Image(systemName: item.returnedAt == nil ? "circle" : "checkmark.circle.fill")
                                        .font(.title2).frame(minWidth: 32, minHeight: 40)
                                }.buttonStyle(.plain)
                                .accessibilityLabel(item.returnedAt == nil ? "Mark \(item.item) returned" : "Mark \(item.item) not returned")
                                Button { editing = item } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.item).strikethrough(item.returnedAt != nil).foregroundStyle(.primary)
                                        Text(item.direction.label).font(.caption).foregroundStyle(.secondary)
                                        if let date = item.returnedAt {
                                            Text("Returned \(date.formatted(date: .abbreviated, time: .omitted))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if !items.isEmpty && !showReturned && items.allSatisfy({ $0.returnedAt != nil }) {
                Text("Everything has been returned. Turn on Show returned items to see the history.").foregroundStyle(.secondary)
            }
        }
        .hippoPage()
        .navigationTitle("Borrowing & Lending")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add item", systemImage: "plus") { editing = BorrowedItem(person: "", item: "", direction: .borrowing) }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { BorrowedItemEditor(item: $0, people: people).frame(minWidth: 320, minHeight: 350) }
        .alert("Borrowing & Lending", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func reload() {
        do { items = try cloud.borrowedItems() } catch { issue = error.localizedDescription }
    }
}

private struct BorrowedItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: BorrowedItem
    let people: [String]
    @State private var issue: String?
    @State private var confirmingDelete = false
    private var valid: Bool {
        !item.person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !item.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Person", text: $item.person, prompt: "Person’s name")
                    if !people.isEmpty {
                        Menu("Choose existing person") {
                            ForEach(people, id: \.self) { person in Button(person) { item.person = person } }
                        }
                    }
                    HippoField("Item", text: $item.item, prompt: "e.g. Ladder or a book")
                    Picker("Who has it?", selection: $item.direction) {
                        ForEach(BorrowedItem.Direction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Returned", isOn: Binding(get: { item.returnedAt != nil }, set: { item.returnedAt = $0 ? Date() : nil }))
                    if item.returnedAt != nil {
                        DatePicker("Returned on", selection: Binding(get: { item.returnedAt ?? Date() }, set: { item.returnedAt = $0 }), displayedComponents: [.date])
                    }
                }
                Section { Button("Delete item", role: .destructive) { confirmingDelete = true } }
            }.hippoForm()
            .navigationTitle("Borrowing or lending")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete item", role: .destructive) { item.deletedAt = Date(); save() }
            }
            .alert("Could not save item", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        item.person = item.person.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse the existing spelling so choosing or typing a person's name groups their items together.
        if let existing = people.first(where: { $0.localizedCaseInsensitiveCompare(item.person) == .orderedSame }) { item.person = existing }
        item.item = item.item.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.saveBorrowedItem(item); dismiss() } catch { issue = error.localizedDescription }
    }
}

struct LastTimeView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @AppStorage("househippo.lasttime.filter") private var filter = "All"
    @State private var entries: [LastTimeEntry] = []
    @State private var editing: LastTimeEntry?
    @State private var issue: String?
    private var visibleEntries: [LastTimeEntry] {
        guard let owner = Reminder.Owner(rawValue: filter) else { return entries }
        if owner == .shared { return entries.filter { $0.assignedTo == .shared } }
        return entries.filter { $0.isVisible(to: owner) }
    }
    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    Text("All markers").tag("All")
                    Text("Shared only").tag(Reminder.Owner.shared.rawValue)
                    Text("Sage + Shared").tag(Reminder.Owner.me.rawValue)
                    Text("Dan + Shared").tag(Reminder.Owner.husband.rawValue)
                }
            }
            if entries.isEmpty {
                HippoEmptyState(title: "Remember the last time", icon: "calendar.badge.clock", message: "Add a marker and a date. See how long it’s been at a glance.")
            }
            if !entries.isEmpty && visibleEntries.isEmpty {
                Text("No markers for this filter.").foregroundStyle(.secondary)
            }
            ForEach(visibleEntries) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).foregroundStyle(.primary)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(entry.elapsed(since: context.date)).font(.callout).foregroundStyle(.teal)
                        }
                        Text(entry.date().formatted(date: .abbreviated, time: .omitted) + " · " + entry.assignedTo.displayName)
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .hippoPage()
        .navigationTitle("Last Time")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add marker", systemImage: "plus") {
                    var entry = LastTimeEntry(title: "")
                    entry.owner = Reminder.Owner(rawValue: filter) ?? .shared
                    editing = entry
                }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { entry in
            LastTimeEditor(entry: entry, isNew: !entries.contains { $0.id == entry.id }).frame(minWidth: 320, minHeight: 350)
        }
        .alert("Last Time", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func reload() {
        do { entries = try cloud.lastTimeEntries() } catch { issue = error.localizedDescription }
    }
}

private struct LastTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: LastTimeEntry
    let isNew: Bool
    @State private var issue: String?
    @State private var confirmingDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Marker", text: $entry.title, prompt: "e.g. Cleaned the gutters")
                    Picker("For", selection: Binding(get: { entry.assignedTo }, set: { entry.owner = $0 })) {
                        ForEach(Reminder.Owner.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("These labels filter markers. All markers are shared with your household.")
                        .font(.caption).foregroundStyle(.secondary)
                    DatePicker("Last time", selection: Binding(get: { entry.date() }, set: { entry.setDate($0) }), in: ...Date(), displayedComponents: [.date])
                    Button("Set to today") { entry.setDate(Date()) }
                }
                if !isNew {
                    Section { Button("Delete marker", role: .destructive) { confirmingDelete = true } }
                }
            }.hippoForm()
            .navigationTitle(isNew ? "Add Last Time marker" : "Edit Last Time marker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this marker?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete marker", role: .destructive) { entry.deletedAt = Date(); save() }
            }
            .alert("Could not save marker", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.saveLastTimeEntry(entry); dismiss() } catch { issue = error.localizedDescription }
    }
}
