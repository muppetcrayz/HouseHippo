import SwiftUI

// Shared field treatment: the label remains visible after typing, and focus is explicit.
struct HippoField: View {
    let label: String
    @Binding var text: String
    var prompt: String = "Enter a value"
    var autofocus = false
    var multiline = false
    @FocusState private var focused: Bool
    init(_ label: String, text: Binding<String>, prompt: String = "Enter a value", autofocus: Bool = false, multiline: Bool = false) {
        self.label = label; _text = text; self.prompt = prompt; self.autofocus = autofocus; self.multiline = multiline
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(prompt, text: $text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain).lineLimit(1...5)
                .padding(.horizontal, 11).padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focused ? 2 : 1) }
                .focused($focused).accessibilityLabel(label)
                .onAppear { if autofocus { focused = true } }
        }.padding(.vertical, 2)
    }
}

struct HippoTextArea: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 110
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(6).frame(minHeight: height, maxHeight: height)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focused ? 2 : 1) }
                .focused($focused).accessibilityLabel(label)
        }.padding(.vertical, 2)
    }
}

struct HippoEmptyState: View {
    let title: String
    let icon: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.teal).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
}

private struct HippoPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            #if os(iOS)
            .listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
    }
}

private struct HippoFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.formStyle(.grouped)
            #if os(iOS)
            .listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
    }
}

extension View {
    @ViewBuilder func hippoPage(enabled: Bool = true) -> some View {
        if enabled { modifier(HippoPageStyle()) } else { self }
    }
    func hippoForm() -> some View { modifier(HippoFormStyle()) }
    @ViewBuilder func hippoInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
