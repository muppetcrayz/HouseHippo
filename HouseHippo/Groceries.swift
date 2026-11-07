import SwiftUI

struct GroceryView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var name = ""
    @State private var editing: GroceryItem?
    @State private var issue: String?
    @State private var confirmingClear = false
    private var items: [GroceryItem] { (try? cloud.groceries()) ?? [] }
    var body: some View {
        let snapshot = items
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Add groceries, e.g. 2 lb apples", text: $name).onSubmit(add)
                Button("Add", systemImage: "plus") { add() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if snapshot.isEmpty { Text("Add your first item. Categories are suggested automatically.").font(.callout).foregroundStyle(.secondary) }
            ForEach(GroceryCategory.allCases, id: \.self) { category in
                let group = snapshot.filter { !$0.checked && $0.category == category }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.rawValue).font(.headline).foregroundStyle(.teal)
                        ForEach(group) { row($0) }
                    }
                }
            }
            let checked = snapshot.filter(\.checked)
            if !checked.isEmpty {
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("Clear checked items (\(checked.count))", systemImage: "trash")
                }
                DisclosureGroup("Checked off (\(checked.count))") { ForEach(checked) { row($0) } }
            }
        }
        .confirmationDialog("Clear all checked grocery items?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear checked items", role: .destructive) {
                do { try cloud.clearCheckedGroceries() } catch { issue = error.localizedDescription }
            }
        } message: { Text("Unchecked items will stay on your list.") }
        .sheet(item: $editing) { GroceryEditor(item: $0).frame(minWidth: 340, minHeight: 260) }
        .task { migrate() }
        .onChange(of: cloud.revision) { _, _ in migrate() }
        .alert("Grocery list", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func row(_ item: GroceryItem) -> some View {
        HStack(spacing: 10) {
            Button {
                var updated = item; updated.checked.toggle()
                do { try cloud.saveGrocery(updated) } catch { issue = error.localizedDescription }
            } label: { Image(systemName: item.checked ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(.teal).frame(width: 32, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(item.checked ? "Uncheck " + item.name : "Check off " + item.name)
            Button { editing = item } label: {
                Text(item.name).strikethrough(item.checked).foregroundStyle(item.checked ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("Edit item") { editing = item }
                Button("Delete", role: .destructive) { do { try cloud.deleteGrocery(item) } catch { issue = error.localizedDescription } }
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 36).contentShape(Rectangle()) }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
        }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try cloud.saveGrocery(GroceryItem(name: value)); name = "" }
        catch { issue = error.localizedDescription }
    }
    private func migrate() { do { try cloud.migrateGroceryText() } catch { issue = error.localizedDescription } }
}

struct GroceryEditor: View {
    @ObservedObject private var cloud = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var item: GroceryItem
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item and quantity", text: $item.name)
                Picker("Category", selection: $item.categoryOverride) {
                    Text("Automatic (\(GroceryCategory.suggest(for: item.name).rawValue))").tag(Optional<GroceryCategory>.none)
                    ForEach(GroceryCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Toggle("Checked off", isOn: $item.checked)
            }.formStyle(.grouped).navigationTitle("Grocery item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        do { try cloud.saveGrocery(item); dismiss() } catch { issue = error.localizedDescription }
                    }.disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not save item", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
}
