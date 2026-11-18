import SwiftUI
import UniformTypeIdentifiers

struct InventoryView: View {
    var body: some View { NavigationStack { InventoryHome() } }
}

/// Inventory without its own navigation stack, so the iPhone Life tab can push it.
struct InventoryHome: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var collections: [InventoryCollection] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var importing = false
    @State private var creating = false
    @State private var preview: InventoryImportDraft?
    @State private var issue: String?
    var body: some View {
        HippoCanvas {
            HippoPageHeader(title: "Inventory", summary: Text(collections.isEmpty ? "No collections yet" : "\(collections.count) " + (collections.count == 1 ? "collection" : "collections") + " · \(counts.values.reduce(0, +)) records"))
            if collections.isEmpty {
                HippoEmptyState(title: "A place for your collections", icon: "archivebox", message: "Create a collection or import a CSV. Column headings become fields, and every row becomes a record.")
                    .padding(.horizontal, 16).hippoCard()
            }
            HippoGrid {
                ForEach(collections) { collection in
                    NavigationLink { InventoryCollectionView(collection: collection) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "archivebox").foregroundStyle(.teal)
                                Text(collection.name).font(.headline).foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                            Text((counts[collection.id] ?? 0) == 1 ? "1 record" : "\(counts[collection.id] ?? 0) records").font(.callout).foregroundStyle(.secondary)
                            Text(collection.fields.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).hippoCard()
                    }.buttonStyle(.plain)
                }
            }
        }
        .hippoCanvasPage("Inventory")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import CSV", systemImage: "square.and.arrow.down") { importing = true }
                    Button("New collection", systemImage: "plus") { creating = true }
                } label: { Label("Add collection", systemImage: "plus") }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let text: String?
                if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
                else { text = String(data: data, encoding: .utf8) }
                guard let text else { throw InventoryCSV.ImportError.invalid("Save this file as a UTF-8 CSV, then try importing again.") }
                preview = InventoryImportDraft(name: url.deletingPathExtension().lastPathComponent, csv: try InventoryCSV(text))
            } catch { issue = error.localizedDescription }
        }
        .sheet(item: $preview) { InventoryImportEditor(draft: $0).frame(minWidth: 340, minHeight: 400) }
        .sheet(isPresented: $creating) { InventoryNewCollectionEditor().frame(minWidth: 340, minHeight: 350) }
        .alert("Inventory", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func reload() {
        do {
            collections = try cloud.inventoryCollections()
            var loaded: [UUID: Int] = [:]
            for collection in collections { loaded[collection.id] = try cloud.inventoryRecords(for: collection.id).count }
            counts = loaded
        } catch { issue = error.localizedDescription }
    }
}

private struct InventoryImportDraft: Identifiable {
    let id = UUID()
    var name: String
    let csv: InventoryCSV
}

private struct InventoryImportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: InventoryImportDraft
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HippoField("Collection name", text: $draft.name, prompt: "e.g. Records")
                    Text("\(draft.csv.rows.count) records · \(draft.csv.fields.count) fields")
                    Text("Values are kept as text, preserving dates, catalog numbers, and leading zeros.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Fields from your header row") {
                    ForEach(draft.csv.fields.indices, id: \.self) { index in Text(draft.csv.fields[index]) }
                }
                if let first = draft.csv.rows.first {
                    Section("First record preview") {
                        ForEach(draft.csv.fields.indices, id: \.self) { index in
                            LabeledContent(draft.csv.fields[index], value: first[index].isEmpty ? "—" : first[index])
                        }
                    }
                }
            }.hippoForm().navigationTitle("Import collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let collection = InventoryCollection(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), fields: draft.csv.fields)
                            try CloudStore.shared.createInventory(collection, rows: draft.csv.rows)
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not import", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
}

private struct InventoryNewCollectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var fields = "Name\nNotes"
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                HippoField("Collection name", text: $name, prompt: "e.g. Stuffed animals")
                Section("Fields · one name per line") { HippoTextArea(label: "Field names", text: $fields, height: 130) }
            }.hippoForm().navigationTitle("New collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let names = fields.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        do {
                            try CloudStore.shared.createInventory(InventoryCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), fields: names), rows: [])
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fields.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not create collection", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
}

private struct InventoryCollectionView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State var collection: InventoryCollection
    @State private var records: [InventoryRecord] = []
    @State private var editing: InventoryRecord?
    @State private var search = ""
    @State private var issue: String?
    @State private var confirmingDelete = false
    @State private var renaming = false
    @State private var name = ""
    private var filtered: [InventoryRecord] {
        records.filter { search.isEmpty || $0.values.contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    private var showsTable: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }
    var body: some View {
        Group {
            if showsTable, #available(macOS 14.4, iOS 17.4, *) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if records.isEmpty { emptyNotice }
                    else {
                        InventoryTable(collection: collection, records: filtered) { editing = $0 }
                            .clipShape(RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
                            .overlay { RoundedRectangle(cornerRadius: HippoLayout.cornerRadius).strokeBorder(Color.primary.opacity(0.08)) }
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(HippoLayout.canvas)
            } else {
                HippoCanvas {
                    header
                    if records.isEmpty { emptyNotice }
                    else if filtered.isEmpty { HippoNotice(text: "No matching records.", icon: "magnifyingglass") }
                    HippoGrid { ForEach(filtered) { recordCard($0) } }
                }
            }
        }
        .navigationTitle(collection.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $search, prompt: "Search all fields")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add record", systemImage: "plus") {
                    editing = InventoryRecord(collectionID: collection.id, values: Array(repeating: "", count: collection.fields.count))
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Main title", selection: Binding(get: { collection.titleFieldIndex ?? 0 }, set: setTitleField)) {
                        Text("None").tag(-1)
                        ForEach(collection.fields.indices, id: \.self) { index in Text(collection.fields[index]).tag(index) }
                    }.pickerStyle(.menu)
                    Button("Rename collection") { name = collection.name; renaming = true }
                    Button("Delete collection", role: .destructive) { confirmingDelete = true }
                } label: { Label("Collection options", systemImage: "ellipsis.circle") }
            }
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { record in
            InventoryRecordEditor(record: record, collection: collection, isNew: !records.contains { $0.id == record.id }).frame(minWidth: 340, minHeight: 400)
        }
        .alert("Rename collection", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                var changed = collection; changed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                do { try cloud.saveInventoryCollection(changed); collection = changed } catch { issue = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete this collection and all its records?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) {
                var deleted = collection; deleted.deletedAt = Date()
                do { try cloud.saveInventoryCollection(deleted); dismiss() } catch { issue = error.localizedDescription }
            }
        }
        .alert("Inventory", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private var header: some View {
        HippoPageHeader(title: collection.name, summary: Text(search.isEmpty ? "\(records.count) records · \(collection.fields.count) fields" : "Showing \(filtered.count) of \(records.count) records"))
    }
    private var emptyNotice: some View {
        HippoNotice(text: "No records yet. Add your first one using this collection’s fields.", icon: "archivebox")
    }
    private func recordCard(_ record: InventoryRecord) -> some View {
        Button { editing = record } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let title = collection.title(for: record) {
                    Text(title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                let details = collection.fields.indices.filter { $0 != collection.effectiveTitleFieldIndex && $0 < record.values.count && !record.values[$0].isEmpty }
                ForEach(Array(details.prefix(3)), id: \.self) { index in
                    Text("\(collection.fields[index]): \(record.values[index])").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if details.count > 3 {
                    Text("+\(details.count - 3) more fields").font(.caption).foregroundStyle(.teal)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).hippoCard()
        }.buttonStyle(.plain)
    }
    private func setTitleField(_ index: Int) {
        var changed = collection
        changed.titleFieldIndex = index
        do { try cloud.saveInventoryCollection(changed); collection = changed; reload() }
        catch { issue = error.localizedDescription }
    }
    private func reload() {
        do {
            guard let current = try cloud.inventoryCollections().first(where: { $0.id == collection.id }) else { dismiss(); return }
            collection = current
            records = try cloud.inventoryRecords(for: collection.id)
        } catch { issue = error.localizedDescription }
    }
}

/// Every field as a column; the main title field comes first. Double-click a row to edit it.
@available(macOS 14.4, iOS 17.4, *)
private struct InventoryTable: View {
    let collection: InventoryCollection
    let records: [InventoryRecord]
    let open: (InventoryRecord) -> Void
    @State private var selection = Set<InventoryRecord.ID>()
    private var columns: [Int] {
        let title = collection.effectiveTitleFieldIndex
        return (title.map { [$0] } ?? []) + collection.fields.indices.filter { $0 != title }
    }
    var body: some View {
        Table(records, selection: $selection) {
            TableColumnForEach(columns, id: \.self) { index in
                TableColumn(collection.fields[index]) { (record: InventoryRecord) in
                    Text(index < record.values.count ? record.values[index] : "")
                        .fontWeight(index == collection.effectiveTitleFieldIndex ? .semibold : .regular)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu(forSelectionType: InventoryRecord.ID.self) { ids in
            if ids.count == 1, let record = records.first(where: { $0.id == ids.first }) {
                Button("Edit record") { open(record) }
            }
        } primaryAction: { ids in
            if let record = records.first(where: { $0.id == ids.first }) { open(record) }
        }
    }
}

private struct InventoryRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: InventoryRecord
    let collection: InventoryCollection
    let isNew: Bool
    @State private var issue: String?
    @State private var confirmingDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section(collection.name) {
                    ForEach(collection.fields.indices, id: \.self) { index in
                        HippoField(collection.fields[index], text: $record.values[index], multiline: true)
                    }
                }
                if !isNew { Section { Button("Delete record", role: .destructive) { confirmingDelete = true } } }
            }.hippoForm().navigationTitle(isNew ? "Add record" : "Edit record")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(record.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
            .confirmationDialog("Delete this record?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete record", role: .destructive) { record.deletedAt = Date(); save() }
            }
            .alert("Could not save record", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
    private func save() {
        do { try CloudStore.shared.saveInventoryRecord(record); dismiss() } catch { issue = error.localizedDescription }
    }
}
