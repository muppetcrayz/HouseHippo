import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
            MoneyLedgerSection()
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
    @State private var payments: [PaymentDue] = []
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
                    NavigationLink { ThingsToPayView() } label: {
                        let unpaid = payments.filter { $0.paidAt == nil }
                        tile("Things To Pay", value: unpaid.count, icon: "creditcard", color: .purple,
                             caption: unpaid.isEmpty ? "Nothing to pay" : MoneyEntry.money(unpaid.reduce(0) { $0 + $1.cents }) + " outstanding")
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
            payments = try cloud.paymentsDue()
            let all = try cloud.inventoryCollections()
            collections = all.count
            records = try all.reduce(0) { $0 + (try cloud.inventoryRecords(for: $1.id).count) }
        } catch { issue = error.localizedDescription }
    }
}

private struct MoneyLedgerSection: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var entries: [MoneyEntry] = []
    @State private var editing: MoneyEntry?
    @State private var importing = false
    @State private var payment: MoneyPayment?
    @State private var showSettled = false
    @State private var issue: String?
    private var people: [String] { Array(Set(entries.map(\.person))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var visiblePeople: [String] { people.filter { person in showSettled || MoneyEntry.balance(entries.filter { $0.person == person }) != 0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Money").font(.title2.bold())
                Spacer()
                Button("Import list", systemImage: "doc.on.clipboard") { importing = true }
                Button("Add money", systemImage: "plus") {
                    editing = MoneyEntry(person: "", title: "", day: MoneyEntry.dayString(Date()), cents: 0)
                }
            }
            Text("Positive amounts: they owe me. Negative amounts: I owe them. Add repayments with the opposite sign.")
                .font(.callout).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("Add a charge, repayment, or import a list to start a balance for someone.").foregroundStyle(.secondary)
            } else {
                let balances = people.map { person in MoneyEntry.balance(entries.filter { $0.person == person }) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { totals(balances) }
                    VStack(alignment: .leading, spacing: 8) { totals(balances) }
                }
                Toggle("Show settled people", isOn: $showSettled)
                if visiblePeople.isEmpty {
                    Text("Everyone is settled up. Add a new charge when someone owes you again.").foregroundStyle(.secondary)
                }
                ForEach(visiblePeople, id: \.self) { person in
                    let ledger = entries.filter { $0.person == person }
                    let balance = MoneyEntry.balance(ledger)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person).font(.headline)
                                Text(balance > 0 ? "Owes me \(MoneyEntry.money(balance))" : balance < 0 ? "I owe \(MoneyEntry.money(-balance))" : "Settled up")
                                    .foregroundStyle(balance < 0 ? Color.orange : Color.teal).monospacedDigit()
                            }
                            Spacer()
                            ShareLink(item: MoneyEntry.summary(person: person, entries: ledger)) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share summary for \(person)")
                            Button("Copy summary", systemImage: "doc.on.doc") { copy(MoneyEntry.summary(person: person, entries: ledger)) }
                                .labelStyle(.iconOnly).accessibilityLabel("Copy summary for \(person)")
                        }
                        if balance != 0 {
                            Button("Record payment", systemImage: "banknote") {
                                payment = MoneyPayment(person: person, balance: balance)
                            }
                        }
                        DisclosureGroup("\(ledger.count) entries · view or edit") {
                            ForEach(MoneyEntry.ordered(ledger)) { entry in
                                Button { editing = entry } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading) {
                                            Text(entry.title).foregroundStyle(.primary)
                                            Text(entry.day).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(MoneyEntry.money(entry.cents, signed: true)).monospacedDigit()
                                            .foregroundStyle(entry.cents < 0 ? Color.orange : Color.teal)
                                    }.padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }.padding(16).hippoCard()
                }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { MoneyEntryEditor(entry: $0, people: people).frame(minWidth: 320, minHeight: 400) }
        .sheet(item: $payment) { payment in
            MoneyEntryEditor(entry: MoneyEntry(person: payment.person, title: "Payment", day: MoneyEntry.dayString(Date()), cents: 0), people: people, paymentBalance: payment.balance)
                .frame(minWidth: 320, minHeight: 400)
        }
        .sheet(isPresented: $importing) { MoneyListImporter(people: people).frame(minWidth: 340, minHeight: 480) }
        .alert("Money", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    @ViewBuilder private func totals(_ balances: [Int]) -> some View {
        Text("Owed to me: \(MoneyEntry.money(balances.filter { $0 > 0 }.reduce(0, +)))")
        Text("I owe: \(MoneyEntry.money(-balances.filter { $0 < 0 }.reduce(0, +)))")
        Text("Net: \(MoneyEntry.money(balances.reduce(0, +), signed: true))").bold()
    }
    private func reload() {
        do { entries = try cloud.moneyEntries() } catch { issue = error.localizedDescription }
    }
    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct MoneyPayment: Identifiable {
    var id = UUID()
    let person: String
    let balance: Int
}

private struct MoneyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: MoneyEntry
    let people: [String]
    var paymentBalance: Int? = nil
    @State private var amount = ""
    @State private var issue: String?
    @State private var confirmingDelete = false
    private var valid: Bool {
        !entry.person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        MoneyEntry.amount(amount).map { cents in
            if let balance = paymentBalance { return MoneyEntry.paymentCents(cents, balance: balance) != nil }
            return cents != 0
        } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Person", text: $entry.person, prompt: "Person’s name").disabled(paymentBalance != nil)
                    if paymentBalance == nil && !people.isEmpty {
                        Menu("Choose existing person") {
                            ForEach(people, id: \.self) { person in Button(person) { entry.person = person } }
                        }
                    }
                    HippoField("Description", text: $entry.title, prompt: "e.g. Groceries or repayment")
                    DatePicker("Date", selection: Binding(get: { entry.date }, set: { entry.day = MoneyEntry.dayString($0) }), displayedComponents: .date)
                    HippoField(paymentBalance == nil ? "Amount ($)" : "Payment amount ($)", text: $amount, prompt: paymentBalance == nil ? "e.g. +24.30 or -15.00" : "e.g. 25.00")
                    if let balance = paymentBalance {
                        Text(balance > 0 ? "Payment received from \(entry.person)" : "Payment made to \(entry.person)")
                        Text("Outstanding: \(MoneyEntry.money(abs(balance)))")
                        Text("Enter a positive amount up to the outstanding balance.").font(.caption).foregroundStyle(.secondary)
                        if let cents = MoneyEntry.amount(amount), let adjustment = MoneyEntry.paymentCents(cents, balance: balance) {
                            Text("Remaining: \(MoneyEntry.money(abs(balance + adjustment)))").bold()
                        }
                    } else {
                    Text("Positive: they owe me. Negative: I owe them. A repayment from them is negative; a repayment from me is positive. Use up to two decimal places.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if entry.cents != 0 {
                    Section { Button("Delete entry", role: .destructive) { confirmingDelete = true } }
                }
            }.hippoForm()
            .navigationTitle(paymentBalance != nil ? "Record payment" : entry.cents == 0 ? "Add money entry" : "Edit money entry")
            .onAppear {
                let cents = paymentBalance.map { abs($0) } ?? entry.cents
                amount = cents == 0 ? "" : String(format: "%.2f", Double(cents) / 100)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            }
            .confirmationDialog("Delete this money entry?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete entry", role: .destructive) { entry.deletedAt = Date(); save() }
            }
            .alert("Could not save entry", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        guard let cents = MoneyEntry.amount(amount) else { return }
        if let balance = paymentBalance {
            guard let adjustment = MoneyEntry.paymentCents(cents, balance: balance) else { return }
            entry.cents = adjustment
        } else { entry.cents = cents }
        entry.person = entry.person.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = people.first(where: { $0.localizedCaseInsensitiveCompare(entry.person) == .orderedSame }) { entry.person = existing }
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.saveMoneyEntry(entry); dismiss() } catch { issue = error.localizedDescription }
    }
}

private struct MoneyListImporter: View {
    @Environment(\.dismiss) private var dismiss
    let people: [String]
    @State private var person = ""
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var text = ""
    @State private var preview: [MoneyEntry] = []
    @State private var saved = 0
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                if preview.isEmpty && saved == 0 {
                    HippoField("Person", text: $person, prompt: "Who is this list with?")
                    if !people.isEmpty {
                        Menu("Choose existing person") {
                            ForEach(people, id: \.self) { name in Button(name) { person = name } }
                        }
                    }
                    Stepper("Year: \(String(year))", value: $year, in: 1900...9999)
                    HippoTextArea(label: "Paste your list", text: $text)
                    Text("One entry per line: 5/9 - Farmer’s Market - +24.30. Negative amounts subtract from what they owe you. Blank lines and standalone totals are ignored; the balance is recalculated.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Section("Review before importing") {
                        Text("\(preview.count) entries for \(person)")
                        Text("Net total: \(MoneyEntry.money(MoneyEntry.balance(preview), signed: true))").bold()
                        if saved > 0 { Text("\(saved) entries already saved. Retry to save the remaining entries.") }
                        ForEach(preview) { entry in
                            LabeledContent("\(entry.day) · \(entry.title)", value: MoneyEntry.money(entry.cents, signed: true))
                        }
                        if saved == 0 { Button("Back to list") { preview = [] } }
                    }
                }
            }.hippoForm()
            .navigationTitle("Import money list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if preview.isEmpty {
                        Button("Review") { review() }.disabled(person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty)
                    } else {
                        Button("Import \(preview.count) entries") { save() }
                    }
                }
            }
            .alert("Money import", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func review() {
        person = person.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = people.first(where: { $0.localizedCaseInsensitiveCompare(person) == .orderedSame }) { person = existing }
        do { preview = try MoneyEntry.parse(text, person: person, year: year) } catch { issue = error.localizedDescription }
    }
    private func save() {
        do {
            while let entry = preview.first {
                try CloudStore.shared.saveMoneyEntry(entry)
                preview.removeFirst(); saved += 1
            }
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct ThingsToPayView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var payments: [PaymentDue] = []
    @State private var editing: PaymentDue?
    @State private var showPaid = false
    @State private var issue: String?
    @State private var markingPaid: PaymentDue?
    private var unpaid: [PaymentDue] { payments.filter { $0.paidAt == nil } }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HippoCanvas {
                HippoPageHeader(title: "Things To Pay", summary: Text("\(unpaid.count) unpaid · \(MoneyEntry.money(unpaid.reduce(0) { $0 + $1.cents })) outstanding")) {
                    Toggle("Show paid", isOn: $showPaid)
                }
                NavigationLink { RecurringBillsView() } label: {
                    Label("Recurring bills & pay periods", systemImage: "repeat")
                        .font(.headline).padding().frame(maxWidth: .infinity, alignment: .leading).hippoCard()
                }
                Text("One-off bills").font(.title2.bold())
                if payments.isEmpty {
                    HippoEmptyState(title: "Keep track of one-off payments", icon: "creditcard", message: "Add tuition, HOA fees, or lessons with their own amounts and due dates.")
                        .padding(.horizontal, 16).hippoCard()
                } else {
                    let dueSoon = unpaid.filter { [.overdue, .today, .soon].contains($0.group(today: context.date)) }
                    Text("Due through the next 7 days: \(MoneyEntry.money(dueSoon.reduce(0) { $0 + $1.cents }))")
                        .font(.headline)
                    if unpaid.isEmpty && !showPaid {
                        HippoNotice(text: "Everything is paid. Turn on Show paid to see the history.", icon: "checkmark.circle")
                    }
                    ForEach(PaymentDue.DueGroup.allCases, id: \.self) { group in
                        let rows = payments.filter { $0.group(today: context.date) == group && (showPaid || $0.paidAt == nil) }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(group.rawValue).font(.headline).foregroundStyle(group == .overdue ? Color.orange : Color.primary)
                                    Spacer()
                                    Text(MoneyEntry.money(rows.reduce(0) { $0 + $1.cents })).monospacedDigit().foregroundStyle(.secondary)
                                }
                                ForEach(rows) { payment in paymentRow(payment) }
                            }
                        }
                    }
                }
            }
        }
        .hippoCanvasPage("Things To Pay")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add payment", systemImage: "plus") {
                    editing = PaymentDue(title: "", cents: 0, day: MoneyEntry.dayString(Date()))
                }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { PaymentDueEditor(payment: $0).hippoFinanceSheet(width: 580, height: 650) }
        .confirmationDialog("Mark this payment as paid?", isPresented: Binding(get: { markingPaid != nil }, set: { if !$0 { markingPaid = nil } }), titleVisibility: .visible) {
            if let payment = markingPaid {
                Button("Mark \(MoneyEntry.money(payment.cents)) paid") { setPaid(payment, paid: true); markingPaid = nil }
            }
        }
        .alert("Things To Pay", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func paymentRow(_ payment: PaymentDue) -> some View {
        HStack(spacing: 12) {
            Button {
                if payment.paidAt == nil { markingPaid = payment } else { setPaid(payment, paid: false) }
            } label: {
                Image(systemName: payment.paidAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(.teal).frame(width: 36, height: 44)
            }.buttonStyle(.plain)
                .accessibilityLabel(payment.paidAt == nil ? "Mark \(payment.title) paid" : "Mark \(payment.title) unpaid")
            Button { editing = payment } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(payment.title).font(.headline).strikethrough(payment.paidAt != nil).foregroundStyle(.primary)
                        Text("Due \(payment.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        if let date = payment.paidAt {
                            Text("Paid \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        if !payment.notes.isEmpty { Text(payment.notes).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    Text(MoneyEntry.money(payment.cents)).monospacedDigit().foregroundStyle(.primary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Edit payment")
        }.padding(14).hippoCard()
    }
    private func setPaid(_ payment: PaymentDue, paid: Bool) {
        var changed = payment; changed.paidAt = paid ? Date() : nil
        do { try cloud.savePaymentDue(changed); reload() } catch { issue = error.localizedDescription }
    }
    private func reload() {
        do { payments = try cloud.paymentsDue() } catch { issue = error.localizedDescription }
    }
}

private struct PaymentDueEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var payment: PaymentDue
    @State private var amount = ""
    @State private var issue: String?
    @State private var confirmingDelete = false
    private var valid: Bool {
        !payment.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && MoneyEntry.amount(amount).map { $0 > 0 } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Payment", text: $payment.title, prompt: "e.g. Tuition or piano lesson")
                    HippoField("Amount ($)", text: $amount, prompt: "e.g. 75.00")
                    DatePicker("Due date", selection: Binding(get: { payment.date }, set: { payment.day = MoneyEntry.dayString($0) }), displayedComponents: .date)
                    HippoTextArea(label: "Notes", text: $payment.notes)
                    Toggle("Paid", isOn: Binding(get: { payment.paidAt != nil }, set: { payment.paidAt = $0 ? Date() : nil }))
                    if payment.paidAt != nil {
                        DatePicker("Paid on", selection: Binding(get: { payment.paidAt ?? Date() }, set: { payment.paidAt = $0 }), displayedComponents: .date)
                    }
                    Text("Each entry is a single payment with its own amount and due date.").font(.caption).foregroundStyle(.secondary)
                }
                if payment.cents != 0 {
                    Section { Button("Delete payment", role: .destructive) { confirmingDelete = true } }
                }
            }.hippoForm()
            .navigationTitle(payment.cents == 0 ? "Add payment" : "Edit payment")
            .onAppear { amount = payment.cents == 0 ? "" : String(format: "%.2f", Double(payment.cents) / 100) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid) }
            }
            .confirmationDialog("Delete this payment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete payment", role: .destructive) { payment.deletedAt = Date(); save() }
            }
            .alert("Could not save payment", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        guard let cents = MoneyEntry.amount(amount), cents > 0 else { return }
        payment.cents = cents
        payment.title = payment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.savePaymentDue(payment); dismiss() } catch { issue = error.localizedDescription }
    }
}

struct RecurringBillsView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var bills: [RecurringBill] = []
    @State private var oneOff: [PaymentDue] = []
    @State private var anchor = MoneyEntry(person: "", title: "", day: "2026-11-27", cents: 0).date
    @State private var offset = 0
    @State private var editing: RecurringBill?
    @State private var priorCarryoverCents = 0
    @State private var budget: PayPeriodBudget?
    @State private var editingBudget: PayPeriodBudget?
    @State private var importing = false
    @State private var issue: String?
    private let calendar = Calendar(identifier: .gregorian)
    private var start: Date { calendar.date(byAdding: .day, value: offset * 14, to: RecurringBill.periodStart(containing: Date(), anchor: anchor))! }
    private var end: Date { calendar.date(byAdding: .day, value: 14, to: start)! }
    @State private var occurrences: [(bill: RecurringBill, date: Date)] = []
    private func updateOccurrences() {
        occurrences = bills.flatMap { bill in bill.occurrences(from: start, to: end).map { (bill: bill, date: $0) } }.sorted { $0.date < $1.date }
    }
    private var periodOneOff: [PaymentDue] { oneOff.filter { $0.paidAt == nil && $0.date >= start && $0.date < end } }
    private var billTotal: Int { occurrences.reduce(0) { $0 + $1.bill.cents } + periodOneOff.reduce(0) { $0 + $1.cents } }
    var body: some View {
        HippoCanvas {
            HippoPageHeader(title: "Recurring bills", summary: Text("Assumed paid · no checkoffs")) { EmptyView() }
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("An every-other-Friday payday", selection: Binding(get: { anchor }, set: { value in
                    guard calendar.component(.weekday, from: value) == 6 else { issue = "Choose a Friday payday."; return }
                    do { try cloud.savePaydayAnchor(MoneyEntry.dayString(value)); anchor = value; offset = 0 } catch { issue = error.localizedDescription }
                }), displayedComponents: .date)
                HStack {
                    Button("Previous") { offset -= 1 }
                    Spacer()
                    Button("Current period") { offset = 0 }
                    Spacer()
                    Button("Next") { offset += 1 }
                }
                Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(calendar.date(byAdding: .day, value: -1, to: end)!.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                Text("Recurring: \(MoneyEntry.money(occurrences.reduce(0) { $0 + $1.bill.cents }))")
                Text("Unpaid one-off bills: \(MoneyEntry.money(periodOneOff.reduce(0) { $0 + $1.cents }))")
                Text("Total to budget: \(MoneyEntry.money(occurrences.reduce(0) { $0 + $1.bill.cents } + periodOneOff.reduce(0) { $0 + $1.cents }))").font(.title2.bold())
                Text("Includes payday Friday through the Thursday before the next payday. One-off totals include unpaid bills due in this period.").font(.callout).foregroundStyle(.secondary)
                ForEach(Array(occurrences.enumerated()), id: \.offset) { _, item in
                    HStack { Text(item.bill.title); Spacer(); Text(item.date.formatted(date: .abbreviated, time: .omitted)); Text(MoneyEntry.money(item.bill.cents)).monospacedDigit() }
                }
                ForEach(periodOneOff) { item in
                    HStack { Text("\(item.title) (one-off)"); Spacer(); Text(item.date.formatted(date: .abbreviated, time: .omitted)); Text(MoneyEntry.money(item.cents)).monospacedDigit() }
                }
                if occurrences.isEmpty && periodOneOff.isEmpty { Text("No bills in this pay period.").foregroundStyle(.secondary) }
            }.padding().hippoCard()
            budgetSummary
            Text("Active recurring bills").font(.title2.bold())
            Text("November 1, 2026 – October 31, 2027. Older series stay active if they still have a bill due in this budget year.").font(.callout).foregroundStyle(.secondary)
            if bills.isEmpty { Text("Add bills or import your Google Calendar .ics export.").foregroundStyle(.secondary) }
            ForEach(bills) { bill in
                Button { editing = bill } label: {
                    HStack { VStack(alignment: .leading) { Text(bill.title).font(.headline); Text("Every \(bill.interval) \(bill.yearly ? "year(s)" : "month(s)") · from \(bill.day)").font(.callout).foregroundStyle(.secondary) }; Spacer(); Text(MoneyEntry.money(bill.cents)) }.padding().hippoCard()
                }.buttonStyle(.plain)
            }
        }
        .hippoCanvasPage("Recurring bills")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Import calendar", systemImage: "square.and.arrow.down") { importing = true }
                Button("Add bill", systemImage: "plus") { editing = RecurringBill(title: "", cents: 0, day: MoneyEntry.dayString(Date())) }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .onChange(of: start) { _, _ in updateOccurrences(); loadBudget() }
        .sheet(item: $editingBudget) { PayPeriodBudgetEditor(budget: $0, billsCents: billTotal, priorCarryoverCents: priorCarryoverCents).hippoFinanceSheet(width: 680, height: 720) }
        .sheet(item: $editing) { RecurringBillEditor(bill: $0).hippoFinanceSheet(width: 580, height: 650) }
        .sheet(isPresented: $importing) { RecurringBillImporter().hippoFinanceSheet(width: 680, height: 720) }
        .alert("Recurring bills", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
    }
    private var budgetSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pay-period budget").font(.title2.bold())
                Spacer()
                Button("Edit budget & paychecks") { editingBudget = budget ?? PayPeriodBudget(startDay: MoneyEntry.dayString(start)) }.disabled(budget == nil)
            }
            if let budget {
                ForEach(budget.paychecks) { paycheck in
                    HStack {
                        Text(paycheck.name + (paycheck.useActualAmount ? "" : " (estimate)"))
                        Spacer()
                        if let net = paycheck.netAmount { Text(MoneyEntry.money(BudgetPaycheck.roundedCents(net))).monospacedDigit() }
                    }
                }
                budgetLine("Paychecks / other income", cents: budget.incomeCents)
                budgetLine("Previous period’s carryover", cents: budget.includePriorCarryover ? priorCarryoverCents : 0)
                budgetLine("Total income", cents: budget.totalIncomeCents(priorCarryoverCents: priorCarryoverCents))
                budgetLine("Bills (automatic)", cents: -billTotal)
                budgetLine("Additional to debt", cents: -budget.additionalDebtCents)
                budgetLine("Investments", cents: -budget.investmentCents)
                budgetLine("Savings", cents: -budget.savingsCents)
                budgetLine("Carryover set aside", cents: -budget.carryoverCents)
                Divider()
                budgetLine("Free spending", cents: budget.freeSpendingCents(billsCents: billTotal, priorCarryoverCents: priorCarryoverCents)).font(.headline)
                if budget.incomeCents == nil { Text("Add paycheck amounts or hours to calculate income and free spending.").foregroundStyle(.secondary) }
                if !budget.notes.isEmpty { Text(budget.notes).font(.callout) }
                Text("Income − bills − extra debt − investments − savings − carryover. Positive carryover is set aside, matching your sheet. Each pay period has its own saved inputs.").font(.callout).foregroundStyle(.secondary)
            }
        }.padding().hippoCard()
    }
    private func budgetLine(_ title: String, cents: Int?) -> some View {
        HStack { Text(title); Spacer(); Text(cents.map { MoneyEntry.money($0) } ?? "—").monospacedDigit() }
    }
    private func loadBudget() {
        budget = nil
        do {
            let loaded = try cloud.payPeriodBudget(startDay: MoneyEntry.dayString(start)) ?? PayPeriodBudget(startDay: MoneyEntry.dayString(start))
            let previous = calendar.date(byAdding: .day, value: -14, to: start)!
            let previousCarryover = try cloud.payPeriodBudget(startDay: MoneyEntry.dayString(previous))?.carryoverCents ?? 0
            priorCarryoverCents = previousCarryover
            budget = loaded
        }
        catch { issue = error.localizedDescription }
    }
    private func reload() {
        do {
            bills = try cloud.recurringBills(); oneOff = try cloud.paymentsDue()
            updateOccurrences()
            if let day = try cloud.paydayAnchor() { anchor = MoneyEntry(person: "", title: "", day: day, cents: 0).date }
            loadBudget()
        } catch { issue = error.localizedDescription }
    }
}

private struct RecurringBillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var bill: RecurringBill
    @State private var amount = ""
    @State private var issue: String?
    @State private var deleting = false
    private var valid: Bool { !bill.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (MoneyEntry.amount(amount) ?? 0) > 0 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Bill", text: $bill.title, prompt: "Bill name")
                    HippoField("Amount ($)", text: $amount, prompt: "12.34")
                    DatePicker("First occurrence", selection: Binding(get: { bill.date }, set: { bill.day = MoneyEntry.dayString($0) }), displayedComponents: .date)
                    Toggle("Yearly", isOn: $bill.yearly)
                    Stepper("Every \(bill.interval) \(bill.yearly ? "years" : "months")", value: $bill.interval, in: 1...120)
                    HippoTextArea(label: "Notes", text: $bill.notes)
                    Text("Assumed paid. Fixed dates skip months without that date (including February 29 in non-leap years).").font(.callout).foregroundStyle(.secondary)
                    if bill.count != nil || bill.until != nil || !bill.excluded.isEmpty { Text("Calendar end limits and excluded dates are preserved.").font(.callout) }
                }
                if bill.cents > 0 { Button("Delete recurring bill", role: .destructive) { deleting = true } }
            }.hippoForm()
            .navigationTitle("Recurring bill")
            .onAppear { amount = bill.cents == 0 ? "" : String(format: "%.2f", Double(bill.cents) / 100) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            }
            .confirmationDialog("Delete recurring bill?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete", role: .destructive) { bill.deletedAt = Date(); save() } }
            .alert("Could not save", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        guard let cents = MoneyEntry.amount(amount), cents > 0 else { return }
        bill.cents = cents; bill.title = bill.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try CloudStore.shared.saveRecurringBill(bill); dismiss() } catch { issue = error.localizedDescription }
    }
}

private struct RecurringBillImporter: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var parsing = false
    @State private var saving = false
    @State private var operation: Task<Void, Never>?
    private var busy: Bool { parsing || saving }
    @State private var bills: [RecurringBill] = []
    @State private var warnings: [String] = []
    @State private var amounts: [UUID: String] = [:]
    @State private var selected: Set<UUID> = []
    @State private var page = 0
    @State private var warningPage = 0
    @State private var issue: String?
    private var valid: Bool { !selected.isEmpty && bills.filter { selected.contains($0.id) }.allSatisfy { (MoneyEntry.amount(amounts[$0.id] ?? "") ?? 0) > 0 } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Export from Google Calendar on a computer") {
                    Text("Open Calendar settings → Import & export → Export. Unzip the download and choose the .ics file for your bills calendar.")
                    Text("Only series with a bill due November 1, 2026 through October 31, 2027 are included. Expired series and series starting after this budget year are skipped. Monthly and yearly series are supported. Other patterns and series with changed individual occurrences are listed for manual review. Reimporting skips existing calendar identities, including deleted bills.")
                    Button("Choose .ics file") { choosing = true }.disabled(busy)
                    if busy { ProgressView(saving ? "Saving bills…" : "Reading calendar…").frame(maxWidth: .infinity, alignment: .leading) }
                }
                if !bills.isEmpty {
                    Section("Review bills and confirm every amount") {
                        if bills.count > 50 {
                            HStack {
                                Button("Previous bills") { page -= 1 }.disabled(page == 0)
                                Spacer()
                                Text("\(page * 50 + 1)–\(min(bills.count, (page + 1) * 50)) of \(bills.count)")
                                Spacer()
                                Button("Next bills") { page += 1 }.disabled((page + 1) * 50 >= bills.count)
                            }
                        }
                        ForEach(Array(bills.dropFirst(page * 50).prefix(50))) { bill in
                            VStack(alignment: .leading) {
                                Toggle(bill.title, isOn: Binding(get: { selected.contains(bill.id) }, set: { if $0 { selected.insert(bill.id) } else { selected.remove(bill.id) } }))
                                Text("\(bill.yearly ? "Yearly" : "Monthly") · every \(bill.interval) · from \(bill.day)").font(.callout)
                                HippoField("Amount ($)", text: Binding(get: { amounts[bill.id] ?? "" }, set: { amounts[bill.id] = $0 }), prompt: "Required")
                            }
                        }
                    }
                }
                if !warnings.isEmpty {
                    Section("Import summary & items to review") {
                        ForEach(Array(warnings.enumerated().dropFirst(warningPage * 50).prefix(50)), id: \.offset) { _, text in Text(text) }
                        if warnings.count > 50 {
                            HStack {
                                Button("Previous messages") { warningPage -= 1 }.disabled(warningPage == 0)
                                Spacer()
                                Text("Page \(warningPage + 1) of \((warnings.count + 49) / 50)")
                                Spacer()
                                Button("Next messages") { warningPage += 1 }.disabled((warningPage + 1) * 50 >= warnings.count)
                            }
                        }
                    }
                }
            }.hippoForm()
            .disabled(saving)
            .navigationTitle("Import recurring bills")
            .interactiveDismissDisabled(busy)
            .onDisappear { operation?.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(parsing ? "Cancel import" : "Cancel") { operation?.cancel(); dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Import \(selected.count) bills") { save() }.disabled(!valid || busy) }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let error): issue = error.localizedDescription
                }
            }
            .alert("Calendar import", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
        }
    }
    private func load(_ url: URL) {
        operation?.cancel()
        parsing = true
        bills = []; selected = []; amounts = [:]; warnings = []; page = 0; warningPage = 0
        operation = Task { @MainActor in
            defer { parsing = false }
            do {
                let preview = try await BillCalendarImport.load(url)
                try Task.checkCancellation()
                let known = Set(try CloudStore.shared.recurringBills(includeDeleted: true).compactMap(\.sourceUID))
                bills = preview.bills.filter { !known.contains($0.sourceUID ?? "") }
                warnings = preview.warnings
                if preview.inactiveCount > 0 { warnings.append("\(preview.inactiveCount) inactive series skipped (no bills due in this budget year).") }
                let skipped = preview.bills.count - bills.count
                if skipped > 0 { warnings.append("\(skipped) previously imported series skipped.") }
                if preview.bills.isEmpty && warnings.isEmpty { warnings = ["No recurring monthly or yearly bills found."] }
                selected = Set(bills.map(\.id))
                amounts = Dictionary(uniqueKeysWithValues: bills.map { ($0.id, $0.cents > 0 ? String(format: "%.2f", Double($0.cents) / 100) : "") })
            } catch is CancellationError { /* Closing the sheet cancels parsing without an alert. */ }
            catch { issue = error.localizedDescription }
        }
    }
    private func save() {
        guard valid, !busy else { return }
        let importing = bills.filter { selected.contains($0.id) }.map { bill in
            var copy = bill; copy.cents = MoneyEntry.amount(amounts[bill.id] ?? "")!; return copy
        }
        saving = true
        operation = Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await CloudStore.shared.importRecurringBills(importing)
                dismiss()
            } catch { issue = error.localizedDescription }
        }
    }

}

private struct PayPeriodBudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var budget: PayPeriodBudget
    let billsCents: Int
    let priorCarryoverCents: Int
    @State private var debt = "0.00"
    @State private var investments = "0.00"
    @State private var savings = "0.00"
    @State private var carryover = "0.00"
    @State private var issue: String?
    private var preview: PayPeriodBudget? {
        guard let debt = MoneyEntry.amount(debt), let investments = MoneyEntry.amount(investments),
              let savings = MoneyEntry.amount(savings), let carryover = MoneyEntry.amount(carryover),
              budget.paychecks.allSatisfy(\.isValid) else { return nil }
        var copy = budget
        copy.additionalDebtCents = debt; copy.investmentCents = investments
        copy.savingsCents = savings; copy.carryoverCents = carryover
        return copy
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Paychecks and other income · \(budget.startDay)") {
                    Text("Enter an actual take-home amount, or estimate it from hours × hourly rate × take-home %. Add each paycheck or other income separately.").font(.callout).foregroundStyle(.secondary)
                    ForEach($budget.paychecks) { $paycheck in
                        VStack(alignment: .leading, spacing: 10) {
                            BudgetPaycheckFields(paycheck: $paycheck)
                            Button("Remove income", role: .destructive) { budget.paychecks.removeAll { $0.id == paycheck.id } }
                        }.padding(.vertical, 8)
                    }
                    Menu("Add paycheck or income", systemImage: "plus") {
                        Button("Dan · estimate from hours") { budget.paychecks.append(.estimate(for: "Dan")) }
                        Button("Sage · estimate from hours") { budget.paychecks.append(.estimate(for: "Sage")) }
                        Button("Actual paycheck / other income") { budget.paychecks.append(BudgetPaycheck()) }
                    }
                }
                Section("Budget allocations ($)") {
                    LabeledContent("Bills (automatic)", value: MoneyEntry.money(billsCents))
                    HippoField("Additional to debt", text: $debt, prompt: "0.00")
                    HippoField("Investments", text: $investments, prompt: "0.00")
                    HippoField("Savings", text: $savings, prompt: "0.00")
                    HippoField("Carryover set aside", text: $carryover, prompt: "0.00")
                    Toggle("Include previous period’s carryover in income", isOn: $budget.includePriorCarryover)
                    LabeledContent("Previous period’s carryover", value: MoneyEntry.money(priorCarryoverCents))
                    Text("Enter positive amounts to set money aside, or negative amounts to release it. Carryover is subtracted, as in your sheet; the next period can include it in income. Investments starts at $25 per new period, matching the sheet, and can be changed.").font(.callout).foregroundStyle(.secondary)
                    HippoTextArea(label: "Notes", text: $budget.notes)
                }
                Section("Budget preview") {
                    if let preview {
                        LabeledContent("Income", value: preview.totalIncomeCents(priorCarryoverCents: priorCarryoverCents).map { MoneyEntry.money($0) } ?? "Add income")
                        LabeledContent("Free spending", value: preview.freeSpendingCents(billsCents: billsCents, priorCarryoverCents: priorCarryoverCents).map { MoneyEntry.money($0) } ?? "Add income")
                    } else { Text("Complete each income entry and use valid dollar amounts for all allocations.").foregroundStyle(.secondary) }
                    Text("Estimated income uses your sheet’s take-home percentages, not a payroll tax calculation. Replace estimates with actual amounts when available. Totals sum unrounded estimates before rounding to cents.").font(.callout).foregroundStyle(.secondary)
                }
            }.hippoForm()
            .navigationTitle("Pay-period budget")
            .onAppear {
                debt = dollars(budget.additionalDebtCents); investments = dollars(budget.investmentCents)
                savings = dollars(budget.savingsCents); carryover = dollars(budget.carryoverCents)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(preview == nil) }
            }
            .alert("Could not save budget", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
        }
    }
    private func dollars(_ cents: Int) -> String { String(format: "%.2f", Double(cents) / 100) }
    private func save() {
        guard let preview else { return }
        do { try CloudStore.shared.savePayPeriodBudget(preview); dismiss() } catch { issue = error.localizedDescription }
    }
}

private struct BudgetPaycheckFields: View {
    @Binding var paycheck: BudgetPaycheck
    var body: some View {
        HippoField("Person / income source", text: $paycheck.name, prompt: "Paycheck, refund, or other income")
        Toggle("Use actual take-home amount", isOn: $paycheck.useActualAmount)
        if paycheck.useActualAmount {
            HippoField("Take-home amount ($)", text: $paycheck.actualAmount, prompt: "Required; zero is allowed")
            HippoField("Hours (optional reference)", text: $paycheck.hours, prompt: "Hours worked")
        } else {
            HippoField("Hours", text: $paycheck.hours, prompt: "e.g. 33.25")
            HippoField("Hourly rate ($)", text: $paycheck.hourlyRate, prompt: "e.g. 50.98")
            HippoField("Take-home (% of gross)", text: $paycheck.takeHomePercent, prompt: "e.g. 82.402603")
            if let amount = paycheck.netAmount { Text("Estimated take-home: \(MoneyEntry.money(BudgetPaycheck.roundedCents(amount)))").font(.headline) }
        }
    }
}
