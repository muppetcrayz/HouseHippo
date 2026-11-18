import SwiftUI

struct GroceryView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var name = ""
    @State private var editing: GroceryItem?
    @State private var issue: String?
    @State private var confirmingClear = false
    @FocusState private var adding: Bool
    private var items: [GroceryItem] { (try? cloud.groceries()) ?? [] }
    var body: some View {
        let snapshot = items
        let checked = snapshot.filter(\.checked)
        VStack(alignment: .leading, spacing: 12) {
            HippoSectionHeader(title: "Groceries", icon: "cart", count: snapshot.count - checked.count, accent: .green) {
                HStack(spacing: 8) {
                    TextField("Add an item, e.g. 2 lb apples", text: $name)
                        .textFieldStyle(.plain).focused($adding).onSubmit { add(); adding = true }
                        .padding(.horizontal, 11).frame(minHeight: 40)
                        .background(.background, in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.4)) }
                        .accessibilityLabel("Add groceries")
                    Button("Add", systemImage: "plus") { add() }.buttonStyle(.borderedProminent).labelStyle(.titleOnly)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(minWidth: 260, maxWidth: 440)
            }
            if snapshot.isEmpty { HippoNotice(text: "Add your first item. Categories are suggested automatically.", icon: "cart", accent: .green) }
            HippoGrid(minimum: 220) {
                ForEach(GroceryCategory.allCases, id: \.self) { category in
                    let group = snapshot.filter { !$0.checked && $0.category == category }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Text(category.rawValue).font(.subheadline.bold()).foregroundStyle(.teal)
                                Text(group.count, format: .number).font(.caption).foregroundStyle(.secondary)
                            }.padding(.bottom, 2)
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                row(item)
                            }
                        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4).hippoCard()
                    }
                }
            }
            if !checked.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    DisclosureGroup("Checked off (\(checked.count))") { ForEach(checked) { row($0) } }
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label("Clear checked items (\(checked.count))", systemImage: "trash")
                    }.buttonStyle(.bordered)
                }.padding(.top, 4)
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
            } label: { Image(systemName: item.checked ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(.teal).frame(width: 32, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(item.checked ? "Uncheck " + item.name : "Check off " + item.name)
            Button { editing = item } label: {
                Text(item.name).strikethrough(item.checked).foregroundStyle(item.checked ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("Edit item") { editing = item }
                Button("Delete", role: .destructive) { do { try cloud.deleteGrocery(item) } catch { issue = error.localizedDescription } }
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 44).contentShape(Rectangle()) }
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
                HippoField("Item and quantity", text: $item.name, prompt: "e.g. 2 lb apples")
                Picker("Category", selection: $item.categoryOverride) {
                    Text("Automatic (\(GroceryCategory.suggest(for: item.name).rawValue))").tag(Optional<GroceryCategory>.none)
                    ForEach(GroceryCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Toggle("Checked off", isOn: $item.checked)
            }.hippoForm().navigationTitle("Grocery item")
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
