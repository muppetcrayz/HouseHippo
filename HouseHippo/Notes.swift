import SwiftUI

struct TaskNoteSection: View {
    @Binding var reminder: Reminder

    var body: some View {
        Section("Task note") {
            if reminder.taskNote == nil && reminder.linkedNoteID != nil {
                Text("Your task note is downloading. Reopen this task once it arrives.")
                    .foregroundStyle(.secondary)
            } else {
                HippoTextArea(label: "Notes", text: Binding(
                    get: { reminder.taskNote ?? "" },
                    set: { reminder.taskNote = $0 }
                ))
            }
        }
    }
}

struct NotesHome: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var notes: [HouseNote] = []
    @State private var editing: HouseNote?
    @State private var search = ""
    @State private var issue: String?
    @State private var reading = false
    @State private var imports: [AppleNoteImportRecord] = []
    @State private var selected: Set<String> = []
    @State private var preview = false
    var body: some View {
        HippoCanvas {
            HippoPageHeader(title: "Notes", summary: Text("Your household notebook"))
            if notes.isEmpty {
                HippoEmptyState(title: "Keep your notes here", icon: "note.text", message: "Create a note, or import from Apple Notes on your Mac. Updates stay in HouseHippo and sync with your household.").hippoCard()
            }
            HippoGrid {
                ForEach(notes.filter { search.isEmpty || ($0.title + " " + $0.body).localizedCaseInsensitiveContains(search) }) { note in
                    Button { editing = note } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.displayTitle).font(.headline)
                            Text(note.body).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).hippoCard()
                    }.buttonStyle(.plain)
                }
            }
            if reading { ProgressView("Reading Apple Notes…") }
        }
        .hippoCanvasPage("Notes")
        .searchable(text: $search)
        .toolbar {
            Button("New note", systemImage: "plus") { editing = HouseNote(title: "", body: "") }
            #if os(macOS)
            Button("Import Apple Notes", systemImage: "square.and.arrow.down") {
                reading = true
                Task {
                    do {
                        imports = try await Task.detached { try AppleNotesReader.read() }.value
                        for index in imports.indices {
                            let paragraphs = AppleNotesReader.parse(imports[index].html)
                            imports[index].paragraphs = paragraphs
                            imports[index].body = paragraphs.map(\.text).joined(separator: "\n")
                        }
                        selected = []
                        preview = true
                    } catch { issue = error.localizedDescription }
                    reading = false
                }
            }.disabled(reading)
            #endif
        }
        .task { reload() }
        .onChange(of: cloud.revision) { _, _ in reload() }
        .sheet(item: $editing) { NoteEditor(note: $0) }
        .sheet(isPresented: $preview) {
            NavigationStack {
                VStack(alignment: .leading) {
                    Text("Choose notes to copy into the shared household. Apple Notes stays unchanged. Reimporting skips existing copies, including deleted notes. Attachments are not copied; locked or unreadable notes are skipped.").padding()
                    List(imports) { record in
                        Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { if $0 { selected.insert(record.id) } else { selected.remove(record.id) } })) {
                            VStack(alignment: .leading) {
                                Text(record.title)
                                Text(record.folder + (record.canImport ? "" : " · Unavailable") + (record.attachments > 0 ? " · Attachments omitted" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!record.canImport)
                    }
                }.navigationTitle("Import Apple Notes")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { preview = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import selected") {
                            do {
                                let result = try cloud.importAppleNotes(imports.filter { selected.contains($0.id) })
                                preview = false
                                issue = "Imported \(result.imported) notes. Skipped \(result.alreadyImported) existing copies and \(result.unreadable) unavailable notes."
                            } catch { issue = error.localizedDescription }
                        }.disabled(selected.isEmpty)
                    }
                }
            }.frame(minWidth: 360, minHeight: 450)
        }
        .alert("Notes", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
    }
    private func reload() {
        do { notes = try cloud.notes() } catch { issue = error.localizedDescription }
    }
}

private struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var note: HouseNote
    @State private var issue: String?
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                HippoField("Title", text: $note.title)
                Section("Note") {
                    ForEach($note.paragraphs.defaultParagraphs) { $paragraph in
                        HStack(alignment: .top) {
                            if paragraph.style == "bullet" { Text("•").padding(.leading, CGFloat(paragraph.depth * 16)) }
                            VStack(alignment: .leading) {
                                Picker("Style", selection: $paragraph.style) {
                                    Text("Text").tag("body")
                                    Text("Heading").tag("h1")
                                    Text("Subheading").tag("h2")
                                    Text("Bullet").tag("bullet")
                                }.labelsHidden()
                                TextField("Text", text: $paragraph.text, axis: .vertical)
                                    .font(paragraph.style == "h1" ? .title2.bold() : paragraph.style == "h2" ? .headline : .body)
                                if paragraph.style == "bullet" { Stepper("Indent: \(paragraph.depth)", value: $paragraph.depth, in: 0...6) }
                            }
                            Button { note.paragraphs?.removeAll { $0.id == paragraph.id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove paragraph")
                        }
                    }
                    Button("Add paragraph", systemImage: "plus") { note.paragraphs?.append(NoteParagraph(text: "")) }
                }
                Button("Delete note", role: .destructive) { deleting = true }
            }
            .navigationTitle("Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        note.body = (note.paragraphs ?? []).map { ($0.style == "bullet" ? "• " : "") + $0.text }.joined(separator: "\n")
                        do { try CloudStore.shared.saveNote(note); dismiss() } catch { issue = error.localizedDescription }
                    }
                }
            }
        }.frame(minWidth: 340, minHeight: 450)
        .onAppear { if note.paragraphs == nil { note.paragraphs = note.body.components(separatedBy: "\n").map { NoteParagraph(text: $0) } } }
        .confirmationDialog("Delete this note from HouseHippo?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { do { try CloudStore.shared.deleteNote(id: note.id); dismiss() } catch { issue = error.localizedDescription } }
        }
        .alert("Note", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
    }
}

private extension Optional where Wrapped == [NoteParagraph] {
    var defaultParagraphs: [NoteParagraph] {
        get { self ?? [] }
        set { self = newValue }
    }
}

#if os(macOS)
import AppKit

private enum AppleNotesReader {
    static func read() throws -> [AppleNoteImportRecord] {
        let source = """
        tell application "Notes"
            set output to {}
            repeat with n in every note
                try
                    if password protected of n then
                        set end of output to {id of n, name of n, "", name of container of n, 0, true, ""}
                    else
                        set end of output to {id of n, name of n, body of n, name of container of n, count of attachments of n, false, ""}
                    end if
                on error
                    set end of output to {"unreadable-" & (count of output), "Unavailable note", "", "", 0, false, "Could not read this note"}
                end try
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw failure("Could not prepare Apple Notes import.") }
        let result = script.executeAndReturnError(&error)
        if let error { throw failure(error[NSAppleScript.errorMessage] as? String ?? "Allow HouseHippo access to Notes in System Settings → Privacy & Security → Automation.") }
        return (1...max(1, result.numberOfItems)).compactMap { index in
            guard let row = result.atIndex(index), row.numberOfItems == 7 else { return nil }
            let html = row.atIndex(3)?.stringValue ?? ""
            return AppleNoteImportRecord(id: row.atIndex(1)?.stringValue ?? "", title: row.atIndex(2)?.stringValue ?? "", body: "", html: html, folder: row.atIndex(4)?.stringValue ?? "", attachments: Int(row.atIndex(5)?.int32Value ?? 0), locked: row.atIndex(6)?.booleanValue ?? false, readError: (row.atIndex(7)?.stringValue ?? "").isEmpty ? nil : row.atIndex(7)?.stringValue)
        }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "HouseHippo.Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private final class EntityReader: NSObject, XMLParserDelegate {
        var text = ""
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    }
    private static func decodeEntities(_ text: String) -> String {
        let reader = EntityReader()
        let parser = XMLParser(data: Data(("<text>" + text.replacingOccurrences(of: "&nbsp;", with: "&#160;") + "</text>").utf8))
        parser.delegate = reader
        return parser.parse() ? reader.text : text
    }
    static func parse(_ html: String) -> [NoteParagraph] {
        // Notes exports block HTML. Walk tags in order so nested lists retain their indentation.
        let regex = try! NSRegularExpression(pattern: "<[^>]+>|[^<]+")
        let ns = html as NSString
        var result: [NoteParagraph] = []
        var text = "", style = "body", depth = 0
        func flush() {
            guard !text.isEmpty else { return }
            let decoded = decodeEntities(text)
            result.append(NoteParagraph(text: decoded, style: style, depth: max(0, depth - 1)))
            text = ""
        }
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let tag = token.lowercased()
            if !token.hasPrefix("<") { text += token; continue }
            if tag.hasPrefix("<ul") || tag.hasPrefix("<ol") { flush(); depth += 1 }
            else if tag.hasPrefix("</ul") || tag.hasPrefix("</ol") { flush(); depth = max(0, depth - 1) }
            else if tag.range(of: "^<(div|p|li|h[1-6])(?:\\s|>)", options: .regularExpression) != nil {
                flush()
                style = tag.hasPrefix("<li") ? "bullet" : tag.hasPrefix("<h1") ? "h1" : tag.hasPrefix("<h") ? "h2" : "body"
            } else if tag.range(of: "^</(div|p|li|h[1-6])>", options: .regularExpression) != nil || tag.hasPrefix("<br") { flush() }
        }
        flush()
        return result
    }
}
#endif
