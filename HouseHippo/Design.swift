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
            TextField("", text: $text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
                .labelsHidden()
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

// MARK: - Page layout shared with the dashboard
// These pieces reproduce the dashboard's look (tinted canvas, white rounded cards,
// section headers with count capsules, metric tiles, adaptive grids) so every page matches it.

enum HippoLayout {
    static let canvas = Color.primary.opacity(0.025)
    static let cornerRadius: CGFloat = 14
    static let cardMinimum: CGFloat = 260
}

/// The scrolling canvas every main page sits on. Matches the dashboard's background and padding.
struct HippoCanvas<Content: View>: View {
    var spacing: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HippoLayout.canvas)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

/// Page heading: a one-line summary plus compact filters. On the Mac the page title is shown here in
/// the dashboard's rounded type; on iPhone and iPad the navigation bar's large title shows it instead.
struct HippoPageHeader<Controls: View>: View {
    let title: String
    var summary: Text?
    @ViewBuilder var controls: Controls
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                heading
                Spacer(minLength: 0)
                HStack(spacing: 10) { controls }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                VStack(alignment: .leading, spacing: 8) { controls }
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(macOS)
            Text(title).font(.system(.largeTitle, design: .rounded).bold())
            #endif
            if let summary { summary.foregroundStyle(.secondary) }
        }
    }
}

extension HippoPageHeader where Controls == EmptyView {
    init(title: String, summary: Text? = nil) { self.init(title: title, summary: summary) { EmptyView() } }
}

/// The dashboard's board heading: icon, bold title, count capsule, optional trailing control.
struct HippoSectionHeader<Trailing: View>: View {
    let title: String
    var icon: String?
    var count: Int?
    var accent: Color = .teal
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { label; Spacer(minLength: 8); trailing }
            VStack(alignment: .leading, spacing: 8) { label; trailing }
        }
    }
    private var label: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(accent) }
            Text(title).font(.title3.bold())
            if let count {
                Text(count, format: .number).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.1), in: Capsule())
            }
        }.accessibilityElement(children: .combine)
    }
}

extension HippoSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, count: Int? = nil, accent: Color = .teal) {
        self.init(title: title, icon: icon, count: count, accent: accent) { EmptyView() }
    }
}

/// Small uppercase label for groups inside a board, such as Overdue or Tomorrow.
struct HippoGroupLabel: View {
    let title: String
    var color: Color = .secondary
    init(_ title: String, color: Color = .secondary) { self.title = title; self.color = color }
    var body: some View {
        Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(color)
            .padding(.top, 6).accessibilityAddTraits(.isHeader)
    }
}

/// The dashboard's metric tile.
struct HippoMetric: View {
    let title: String
    let value: Int
    let icon: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value, format: .number).font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
            .accessibilityElement(children: .combine)
    }
}

/// Adaptive card grid; adds columns as the window widens, like the dashboard boards.
struct HippoGrid<Content: View>: View {
    var minimum: CGFloat = HippoLayout.cardMinimum
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) { content }
    }
}

private struct HippoCardStyle: ViewModifier {
    var border: Color
    var lineWidth: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.background, in: RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: HippoLayout.cornerRadius).strokeBorder(border, lineWidth: lineWidth) }
            .contentShape(RoundedRectangle(cornerRadius: HippoLayout.cornerRadius))
    }
}

/// An empty or informational message shown on a card.
struct HippoNotice: View {
    let text: String
    var icon: String = "checkmark.circle"
    var accent: Color = .teal
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(accent)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).hippoCard()
    }
}

extension View {
    /// White rounded card with the dashboard's hairline border.
    func hippoCard(border: Color = Color.primary.opacity(0.08), lineWidth: CGFloat = 1) -> some View {
        modifier(HippoCardStyle(border: border, lineWidth: lineWidth))
    }
    /// Navigation styling for canvas pages: large titles on iPhone and iPad.
    func hippoCanvasPage(_ title: String) -> some View {
        navigationTitle(title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
    }
}


extension View {
    /// Mac sheets need an explicit usable canvas; iPhone sheets follow the system width.
    @ViewBuilder func hippoFinanceSheet(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, maxWidth: width + 120,
                   minHeight: 480, idealHeight: height, maxHeight: height + 100)
        #else
        self
        #endif
    }
}
