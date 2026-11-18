import SwiftUI
import UniformTypeIdentifiers

struct InventoryView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var collections: [InventoryCollection] = []
    @State private var importing = false
    @State private var creating = false
    @State private var preview: InventoryImportDraft?
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            List {
                if collections.isEmpty {
                    HippoEmptyState(title: "A place for your collections", icon: "archivebox", message: "Create a collection or import a CSV. Column headings become fields, and every row becomes a record.")
                }
                ForEach(collections) { collection in
                    NavigationLink { InventoryCollectionView(collection: collection) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.name)
                            Text(collection.fields.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .hippoPage()
            .navigationTitle("Inventory")
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
    }
    private func reload() {
        do { collections = try cloud.inventoryCollections() } catch { issue = error.localizedDescription }
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
    var body: some View {
        List {
            Section {
                Picker("Main title", selection: Binding(get: { collection.titleFieldIndex ?? 0 }, set: setTitleField)) {
                    Text("None").tag(-1)
                    ForEach(collection.fields.indices, id: \.self) { index in Text(collection.fields[index]).tag(index) }
                }
            }
            if records.isEmpty { Text("No records yet. Add your first one using this collection’s fields.").foregroundStyle(.secondary) }
            else if filtered.isEmpty { Text("No matching records.").foregroundStyle(.secondary) }
            Section("\(filtered.count) of \(records.count) records") {
                ForEach(filtered) { record in
                    Button { editing = record } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if let title = collection.title(for: record) {
                                Text(title).font(.headline).foregroundStyle(.primary)
                            }
                            let details = collection.fields.indices.filter { $0 != collection.effectiveTitleFieldIndex && $0 < record.values.count && !record.values[$0].isEmpty }
                            ForEach(Array(details.prefix(3)), id: \.self) { index in
                                Text("\(collection.fields[index]): \(record.values[index])").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if details.count > 3 {
                                Text("+\(details.count - 3) more fields").font(.caption).foregroundStyle(.teal)
                            }
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .hippoPage()
        .navigationTitle(collection.name)
        .searchable(text: $search, prompt: "Search all fields")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add record", systemImage: "plus") {
                    editing = InventoryRecord(collectionID: collection.id, values: Array(repeating: "", count: collection.fields.count))
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
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
