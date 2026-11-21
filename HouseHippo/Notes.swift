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
    @State private var resetting = false
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
                            NoteMarkdownPreview(markdown: note.markdownText, maximumLines: 4)
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).hippoCard()
                    }.buttonStyle(.plain)
                }
            }
            if reading { ProgressView("Reading Apple Notes…") }
        }
        .hippoCanvasPage("Notes")
        .searchable(text: $search)
        .toolbar {
            Button("Clear notebook…", systemImage: "trash") { resetting = true }.disabled(reading)
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
        .confirmationDialog("Clear the HouseHippo notebook?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Clear notebook & allow fresh import", role: .destructive) {
                do { try cloud.resetNotebook(); imports = []; selected = [] } catch { issue = error.localizedDescription }
            }
        } message: {
            Text("This removes every notebook note, including old imports and HouseHippo edits, for the whole household. Task notes and Apple Notes are kept. You can then choose notes to import again.")
        }
        .sheet(item: $editing) { NoteEditor(note: $0) }
        .sheet(isPresented: $preview) {
            NavigationStack {
                VStack(alignment: .leading) {
                    Text("Choose notes to copy into the shared household. Apple Notes stays unchanged. Reimporting skips existing copies, including deleted notes. Attachments are not copied; locked or unreadable notes are skipped.").padding()
                    List(imports) { record in
                        Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { if $0 { selected.insert(record.id) } else { selected.remove(record.id) } })) {
                            VStack(alignment: .leading) {
                                Text(record.title)
                                Text(record.folder + (record.locked ? " · Locked" : record.readError == nil ? "" : " · Unavailable") + (record.attachments > 0 ? " · Attachments omitted" : "")).font(.caption).foregroundStyle(.secondary)
                                if let error = record.readError {
                                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
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
    @State private var markdown: String
    @State private var previewing = true
    @State private var issue: String?
    @State private var deleting = false

    init(note: HouseNote) {
        _note = State(initialValue: note)
        _markdown = State(initialValue: note.markdownText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HippoField("Title", text: $note.title)
                Picker("View", selection: $previewing) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }.pickerStyle(.segmented)
                if previewing {
                    ScrollView { NoteMarkdownPreview(markdown: markdown).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    Text("# Heading   ·   ## Subheading   ·   - Bullet").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $markdown)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)) }
                        .accessibilityLabel("Markdown note")
                }
            }.padding().navigationTitle("Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Delete", systemImage: "trash", role: .destructive) { deleting = true } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        note.body = markdown
                        note.paragraphs = nil
                        do { try CloudStore.shared.saveNote(note); dismiss() } catch { issue = error.localizedDescription }
                    }
                }
            }
        }.frame(minWidth: 340, idealWidth: 720, minHeight: 500, idealHeight: 650)
        .confirmationDialog("Delete this note from HouseHippo?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { do { try CloudStore.shared.deleteNote(id: note.id); dismiss() } catch { issue = error.localizedDescription } }
        }
        .alert("Note", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK") { issue = nil } } message: { Text(issue ?? "") }
    }
}

private struct NoteMarkdownPreview: View {
    let markdown: String
    var maximumLines: Int? = nil
    private var lines: [String] { markdown.components(separatedBy: "\n") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.prefix(maximumLines ?? lines.count).enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                    Text(String(trimmed.dropFirst(hashes + 1)))
                        .font(hashes == 1 ? .title.bold() : hashes == 2 ? .title2.bold() : .headline)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        inline(String(trimmed.dropFirst(2)))
                    }.padding(.leading, CGFloat(line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }) * 8)
                } else if line.isEmpty {
                    Text(" ")
                } else {
                    inline(line)
                }
            }
            if let maximumLines, lines.count > maximumLines {
                Text("…").accessibilityLabel("Open note to read more")
            }
        }.lineLimit(maximumLines == nil ? nil : 1)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
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
                set noteID to "unreadable-" & (count of output)
                set noteTitle to "Unavailable note"
                set folderName to ""
                set attachmentCount to 0
                try
                    set noteID to get id of n
                    set noteTitle to get name of n
                    -- Resolve the folder object before asking for its name. Chained
                    -- specifiers fail for Notes' note-list references with error -1728.
                    try
                        set noteFolder to get container of n
                        set folderName to get name of noteFolder
                    end try
                    try
                        set attachmentCount to count of attachments of n
                    end try
                    if password protected of n then
                        set end of output to {noteID, noteTitle, "", folderName, attachmentCount, true, ""}
                    else
                        set noteHTML to get body of n
                        set end of output to {noteID, noteTitle, noteHTML, folderName, attachmentCount, false, ""}
                    end if
                on error errorMessage number errorNumber
                    set end of output to {noteID, noteTitle, "", folderName, attachmentCount, false, errorMessage & " (" & errorNumber & ")"}
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
