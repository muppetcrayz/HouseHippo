import SwiftUI

struct WaitingForView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @AppStorage("househippo.waiting.sort") private var sort = "Recent"
    @State private var records: [WaitingRecord] = []
    @State private var updates: [UUID: [WaitingUpdate]] = [:]
    @State private var selection: UUID?
    @State private var search = ""
    @State private var adding = false
    @State private var issue: String?
    private func latest(_ record: WaitingRecord) -> Date { updates[record.id]?.first?.date ?? record.createdAt }
    private var visible: [WaitingRecord] {
        let matching = records.filter { record in
            search.isEmpty || record.title.localizedCaseInsensitiveContains(search) || (updates[record.id] ?? []).contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
        return matching.sorted { sort == "Quiet" ? latest($0) < latest($1) : latest($0) > latest($1) }
    }
    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 760 { split } else { stacked }
        }
        .background(HippoLayout.canvas)
        .hippoCanvasPage("Waiting For")
        .searchable(text: $search, prompt: "Search records")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add record", systemImage: "plus") { adding = true } } }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(isPresented: $adding) { WaitingRecordCreator().frame(minWidth: 340, minHeight: 240) }
        .alert("Waiting For", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private var header: some View {
        HippoPageHeader(title: "Waiting For", summary: summary) {
            Picker("Sort", selection: $sort) { Text("Recently updated").tag("Recent"); Text("Quiet longest").tag("Quiet") }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
    private var summary: Text {
        guard let quietest = records.map(latest).min() else { return Text("Nothing open") }
        return Text("\(records.count) open · oldest update \(quietest.formatted(.relative(presentation: .named)))")
    }
    /// Wide windows: records on the left, the selected record's history on the right.
    private var split: some View {
        VStack(alignment: .leading, spacing: 18) {
            header.padding([.horizontal, .top], 20)
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if records.isEmpty { emptyState }
                        ForEach(visible) { record in
                            Button { selection = record.id } label: { recordCard(record, selected: record.id == currentSelection) }.buttonStyle(.plain)
                        }
                    }.padding(.bottom, 20)
                }.frame(width: 340)
                ScrollView {
                    if let record = records.first(where: { $0.id == currentSelection }) {
                        WaitingRecordView(record: record, embedded: true).id(record.id).padding(.bottom, 20)
                    } else if !records.isEmpty {
                        HippoNotice(text: "Choose a record to see its updates.", icon: "clock")
                    }
                }.frame(maxWidth: .infinity)
            }.padding(.horizontal, 20)
        }
    }
    private var currentSelection: UUID? {
        if let selection, records.contains(where: { $0.id == selection }) { return selection }
        return visible.first?.id
    }
    private var stacked: some View {
        HippoCanvas {
            header
            if records.isEmpty { emptyState }
            LazyVStack(spacing: 8) {
                ForEach(visible) { record in
                    NavigationLink { WaitingRecordView(record: record) } label: { recordCard(record, selected: false) }.buttonStyle(.plain)
                }
            }
        }
    }
    private var emptyState: some View {
        HippoEmptyState(title: "What are you waiting for?", icon: "clock", message: "Add a record, then keep dated updates as things happen.")
            .padding(.horizontal, 16).hippoCard()
    }
    private func recordCard(_ record: WaitingRecord, selected: Bool) -> some View {
        let history = updates[record.id] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(record.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Text(history.first?.text ?? "No updates yet").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(latest(record).formatted(.relative(presentation: .named)) + " · " + (history.count == 1 ? "1 update" : "\(history.count) updates"))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
        .background(selected ? Color.teal.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
        .hippoCard(border: selected ? .teal : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
    }
    private func reload() {
        do {
            records = try cloud.waitingRecords()
            var loaded: [UUID: [WaitingUpdate]] = [:]
            for record in records { loaded[record.id] = try cloud.waitingUpdates(for: record.id) }
            updates = loaded
        } catch { issue = error.localizedDescription }
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
    var embedded = false
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var taskDraft: Reminder?
    @State private var updates: [WaitingUpdate] = []
    @State private var editing: WaitingUpdate?
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var editingTitle = false
    @State private var title = ""
    @State private var draft = ""
    @FocusState private var composing: Bool
    var body: some View {
        Group {
            if embedded { content }
            else {
                HippoCanvas { content }
                    .navigationTitle(record.title).hippoInlineTitle()
                    .toolbar { ToolbarItem(placement: .primaryAction) { optionsMenu } }
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
                do { try cloud.saveWaitingRecord(deleted); if !embedded { dismiss() } } catch { issue = error.localizedDescription }
            }
        }
        .alert("Waiting For", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.title2.bold())
                    Text("Started \(record.createdAt.formatted(date: .abbreviated, time: .omitted)) · " + (updates.count == 1 ? "1 update" : "\(updates.count) updates"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if embedded { optionsMenu }
            }
            HStack(alignment: .bottom, spacing: 10) {
                HippoField("Add an update", text: $draft, prompt: "What happened?").focused($composing).onSubmit(addUpdate)
                Button("Add", action: addUpdate).buttonStyle(.borderedProminent).frame(minHeight: 48)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if updates.isEmpty { Text("No updates yet.").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 4) {
                            Circle().fill(index == 0 ? Color.teal : Color.secondary.opacity(0.4)).frame(width: 10, height: 10).padding(.top, 4)
                            if index < updates.count - 1 { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 2) }
                        }.frame(width: 12)
                        VStack(alignment: .leading, spacing: 6) {
                            Button { editing = update } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(update.date.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(update.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityHint("Edit this update")
                            Button("Make a flexible task", systemImage: "plus.circle") {
                                taskDraft = update.flexibleTask(recordTitle: record.title, owner: Reminder.Owner(rawValue: person) ?? .me)
                            }.font(.caption).buttonStyle(.borderless)
                        }.padding(.bottom, 18)
                    }
                }
            }
        }
        .padding(20).hippoCard()
    }
    private var optionsMenu: some View {
        Menu {
            Button("Edit title") { title = record.title; editingTitle = true }
            Button("Delete record", role: .destructive) { confirmingDelete = true }
        } label: { Label("Record options", systemImage: "ellipsis.circle").labelStyle(.iconOnly).font(.title3) }
        #if os(macOS)
        .menuStyle(.borderlessButton).fixedSize()
        #endif
    }
    private func addUpdate() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do { try cloud.saveWaitingUpdate(WaitingUpdate(recordID: record.id, text: text)); draft = ""; reload(); composing = true }
        catch { issue = error.localizedDescription }
    }
    private func reload() {
        do {
            guard let current = try cloud.waitingRecords().first(where: { $0.id == record.id }) else { if !embedded { dismiss() }; return }
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
    private var out: [BorrowedItem] { items.filter { $0.returnedAt == nil } }
    var body: some View {
        HippoCanvas {
            HippoPageHeader(title: "Borrowing & Lending", summary: Text(out.isEmpty ? "Nothing out right now" : "\(out.count) out with \(Set(out.map(\.person)).count) " + (Set(out.map(\.person)).count == 1 ? "person" : "people"))) {
                Picker("Show", selection: $showReturned) { Text("Out now").tag(false); Text("Include returned").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if items.isEmpty {
                HippoEmptyState(title: "Keep track of who has what", icon: "arrow.left.arrow.right", message: "Add an item and a person. Check it off when it’s returned.")
                    .padding(.horizontal, 16).hippoCard()
            } else {
                HStack(spacing: 10) {
                    HippoMetric(title: BorrowedItem.Direction.borrowing.label, value: out.filter { $0.direction == .borrowing }.count, icon: "arrow.down.left", color: .orange)
                    HippoMetric(title: BorrowedItem.Direction.lending.label, value: out.filter { $0.direction == .lending }.count, icon: "arrow.up.right", color: .teal)
                }
                if !showReturned && out.isEmpty {
                    HippoNotice(text: "Everything has been returned. Choose Include returned to see the history.")
                }
                HippoGrid(minimum: 280) {
                    ForEach(people, id: \.self) { person in
                        let visible = items.filter { $0.person == person && (showReturned || $0.returnedAt == nil) }
                        if !visible.isEmpty { personCard(person, items: visible) }
                    }
                }
            }
        }
        .hippoCanvasPage("Borrowing & Lending")
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
    private func personCard(_ person: String, items: [BorrowedItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(String(person.prefix(1)).uppercased()).font(.subheadline.bold()).foregroundStyle(.teal)
                    .frame(width: 32, height: 32).background(Color.teal.opacity(0.12), in: Circle()).accessibilityHidden(true)
                Text(person).font(.headline)
                Spacer()
                Text(items.count == 1 ? "1 item" : "\(items.count) items").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 6)
            ForEach(items) { item in
                Divider()
                HStack(spacing: 10) {
                    Button {
                        var changed = item
                        changed.returnedAt = item.returnedAt == nil ? Date() : nil
                        do { try cloud.saveBorrowedItem(changed); reload() } catch { issue = error.localizedDescription }
                    } label: {
                        Image(systemName: item.returnedAt == nil ? "circle" : "checkmark.circle.fill").font(.title3).foregroundStyle(.teal)
                            .frame(width: 32, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel(item.returnedAt == nil ? "Mark \(item.item) returned" : "Mark \(item.item) not returned")
                    Button { editing = item } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.item).strikethrough(item.returnedAt != nil).foregroundStyle(item.returnedAt == nil ? .primary : .secondary)
                                if let date = item.returnedAt {
                                    Text("Returned \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(item.direction.label).font(.caption2.weight(.semibold))
                                .foregroundStyle(item.direction == .borrowing ? Color.orange : Color.teal)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background((item.direction == .borrowing ? Color.orange : Color.teal).opacity(0.12), in: Capsule())
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4).hippoCard()
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var entries: [LastTimeEntry] = []
    @State private var editing: LastTimeEntry?
    @State private var markingToday: LastTimeEntry?
    @State private var issue: String?
    private var visibleEntries: [LastTimeEntry] {
        let all: [LastTimeEntry]
        if let owner = Reminder.Owner(rawValue: filter) {
            all = owner == .shared ? entries.filter { $0.assignedTo == .shared } : entries.filter { $0.isVisible(to: owner) }
        } else { all = entries }
        return all.sorted { $0.date() < $1.date() }
    }
    private var tileMinimum: CGFloat {
        #if os(iOS)
        sizeClass == .compact ? 150 : 220
        #else
        220
        #endif
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HippoCanvas {
                HippoPageHeader(title: "Last Time", summary: Text(entries.isEmpty ? "No markers yet" : (visibleEntries.count == 1 ? "1 marker" : "\(visibleEntries.count) markers") + " · longest ago first")) {
                    Picker("Show", selection: $filter) {
                        Text("All").tag("All")
                        Text("Shared").tag(Reminder.Owner.shared.rawValue)
                        Text("Sage").tag(Reminder.Owner.me.rawValue)
                        Text("Dan").tag(Reminder.Owner.husband.rawValue)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if entries.isEmpty {
                    HippoEmptyState(title: "Remember the last time", icon: "calendar.badge.clock", message: "Add a marker and a date. See how long it’s been at a glance.")
                        .padding(.horizontal, 16).hippoCard()
                } else if visibleEntries.isEmpty {
                    HippoNotice(text: "No markers for this filter.", icon: "calendar")
                }
                ForEach(bands(at: context.date), id: \.0) { band in
                    VStack(alignment: .leading, spacing: 12) {
                        HippoSectionHeader(band.0, count: band.1.count)
                        HippoGrid(minimum: tileMinimum, spacing: 10) {
                            ForEach(band.1) { tile($0, now: context.date) }
                        }
                    }
                }
            }
        }
        .hippoCanvasPage("Last Time")
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
        .confirmationDialog("Set this marker to today?", isPresented: Binding(get: { markingToday != nil }, set: { if !$0 { markingToday = nil } }), titleVisibility: .visible, presenting: markingToday) { entry in
            Button("Set “\(entry.title)” to today") {
                var changed = entry; changed.setDate(Date())
                do { try cloud.saveLastTimeEntry(changed); reload() } catch { issue = error.localizedDescription }
            }
        } message: { entry in Text("It was last set to \(entry.date().formatted(date: .abbreviated, time: .omitted)).") }
        .alert("Last Time", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    /// Markers grouped by how long ago they happened, oldest first.
    private func bands(at now: Date) -> [(String, [LastTimeEntry])] {
        let calendar = Calendar(identifier: .gregorian)
        func months(_ entry: LastTimeEntry) -> Int { calendar.dateComponents([.month], from: entry.date(), to: calendar.startOfDay(for: now)).month ?? 0 }
        return [
            ("Over 3 months", visibleEntries.filter { months($0) >= 3 }),
            ("1 to 3 months", visibleEntries.filter { (1..<3).contains(months($0)) }),
            ("This month", visibleEntries.filter { months($0) < 1 })
        ].filter { !$0.1.isEmpty }
    }
    /// Splits the elapsed time into a large number and a unit, e.g. "7" and "months ago".
    private func elapsedParts(_ entry: LastTimeEntry, now: Date) -> (String, String) {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: entry.date(), to: today).day ?? 0
        if days < 0 { return ("Soon", "") }
        if days == 0 { return ("Today", "") }
        if days == 1 { return ("Yesterday", "") }
        let parts = calendar.dateComponents([.year, .month], from: entry.date(), to: today)
        if let years = parts.year, years > 0 { return ("\(years)", years == 1 ? "year ago" : "years ago") }
        if let months = parts.month, months > 0 { return ("\(months)", months == 1 ? "month ago" : "months ago") }
        if days >= 7 { let weeks = days / 7; return ("\(weeks)", weeks == 1 ? "week ago" : "weeks ago") }
        return ("\(days)", "days ago")
    }
    private func tile(_ entry: LastTimeEntry, now: Date) -> some View {
        let elapsed = elapsedParts(entry, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            Button { editing = entry } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(elapsed.0).font(.system(.title, design: .rounded).bold()).foregroundStyle(.teal).monospacedDigit()
                        Text(elapsed.1).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(entry.title), \(entry.elapsed(since: now))")
            if elapsed.0 == "Today" { meta(entry) }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { meta(entry); Spacer(minLength: 4); todayButton(entry) }
                    VStack(alignment: .leading, spacing: 6) { meta(entry); todayButton(entry) }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).hippoCard()
        .contextMenu {
            Button("Set to today", systemImage: "checkmark") { markingToday = entry }
            Button("Edit marker", systemImage: "pencil") { editing = entry }
        }
    }
    private func meta(_ entry: LastTimeEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.date().formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
            Text(entry.assignedTo.displayName).font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: Capsule())
        }.fixedSize()
    }
    private func todayButton(_ entry: LastTimeEntry) -> some View {
        Button("Today", systemImage: "checkmark") { markingToday = entry }
            .font(.caption).buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Set \(entry.title) to today")
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

/// iPhone and iPad tab that gathers the Life Management sections, keeping the tab bar to five tabs.
struct LifeHubView: View {
    @ObservedObject private var cloud = CloudStore.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var waiting: [WaitingRecord] = []
    @State private var latestUpdates: [UUID: WaitingUpdate] = [:]
    @State private var borrowed: [BorrowedItem] = []
    @State private var markers: [LastTimeEntry] = []
    @State private var collections = 0
    @State private var records = 0
    @State private var issue: String?
    private var out: [BorrowedItem] { borrowed.filter { $0.returnedAt == nil } }
    private var recent: [WaitingRecord] {
        waiting.sorted { (latestUpdates[$0.id]?.date ?? $0.createdAt) > (latestUpdates[$1.id]?.date ?? $1.createdAt) }
    }
    var body: some View {
        NavigationStack {
            HippoCanvas {
                HippoPageHeader(title: "Life", summary: Text("What you're keeping track of"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: tileColumns), spacing: 10) {
                    NavigationLink { WaitingForView() } label: {
                        tile("Waiting For", value: waiting.count, icon: "clock", color: .teal,
                             caption: waiting.isEmpty ? "Nothing open" : "\(waiting.count) open")
                    }
                    NavigationLink { BorrowingLendingView() } label: {
                        tile("Borrowing & Lending", value: out.count, icon: "arrow.left.arrow.right", color: .orange,
                             caption: out.isEmpty ? "Nothing out" : "With \(Set(out.map(\.person)).count) " + (Set(out.map(\.person)).count == 1 ? "person" : "people"))
                    }
                    NavigationLink { LastTimeView() } label: {
                        let oldest = markers.min { $0.date() < $1.date() }
                        tile("Last Time", value: markers.count, icon: "calendar.badge.clock", color: .indigo,
                             caption: oldest.map { "\($0.title), \($0.elapsed().lowercased())" } ?? "No markers yet")
                    }
                    NavigationLink { InventoryHome() } label: {
                        tile("Inventory", value: collections, icon: "archivebox", color: .green,
                             caption: records == 1 ? "1 record" : "\(records) records")
                    }
                }.buttonStyle(.plain)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HippoSectionHeader("Recently updated", icon: "clock")
                        ForEach(recent.prefix(3)) { record in
                            NavigationLink { WaitingRecordView(record: record) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(record.title).font(.headline).foregroundStyle(.primary)
                                        Spacer(minLength: 8)
                                        Text((latestUpdates[record.id]?.date ?? record.createdAt).formatted(.relative(presentation: .named)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(latestUpdates[record.id]?.text ?? "No updates yet").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).hippoCard()
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .hippoCanvasPage("Life")
            .task { reload() }
            .onChange(of: cloud.revision) { _, _ in reload() }
            .alert("Life", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private var tileColumns: Int {
        #if os(iOS)
        sizeClass == .compact ? 2 : 4
        #else
        4
        #endif
    }
    private func tile(_ title: String, value: Int, icon: String, color: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(height: 22)
            Text(value, format: .number).font(.system(.title, design: .rounded).bold()).monospacedDigit().foregroundStyle(.primary)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading).padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
        .accessibilityElement(children: .combine)
    }
    private func reload() {
        do {
            waiting = try cloud.waitingRecords()
            var latest: [UUID: WaitingUpdate] = [:]
            for record in waiting { latest[record.id] = try cloud.waitingUpdates(for: record.id).first }
            latestUpdates = latest
            borrowed = try cloud.borrowedItems()
            markers = try cloud.lastTimeEntries()
            let all = try cloud.inventoryCollections()
            collections = all.count
            records = try all.reduce(0) { $0 + (try cloud.inventoryRecords(for: $1.id).count) }
        } catch { issue = error.localizedDescription }
    }
}
