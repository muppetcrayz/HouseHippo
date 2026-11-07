import SwiftUI

struct NoteEditor: View {
    @ObservedObject private var cloud = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var note: HouseNote
    var onSave: ((HouseNote) -> Void)? = nil
    @State private var issue: String?
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Note title", text: $note.title)
                TextEditor(text: $note.body).frame(minHeight: 240)
                if (note.appleNotesAttachmentCount ?? 0) > 0 {
                    Text("This note's photos, scans and files remain in Apple Notes; only text was copied.").font(.caption).foregroundStyle(.secondary)
                }
                if (try? cloud.note(id: note.id)) != nil {
                    Button("Delete note", role: .destructive) { deleting = true }
                }
            }.formStyle(.grouped)
            .navigationTitle(note.displayTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try cloud.saveNote(note); onSave?(note); dismiss() }
                        catch { issue = error.localizedDescription }
                    }.disabled(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete note", role: .destructive) {
                    do { try cloud.deleteNote(id: note.id); dismiss() }
                    catch { issue = error.localizedDescription }
                }
            } message: { Text("The note will be removed and unlinked from tasks. Your tasks will remain.") }
            .alert("Could not save note", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }
}

struct TaskLinkedNoteSection: View {
    @ObservedObject private var cloud = CloudStore.shared
    @Binding var reminder: Reminder
    @State private var editing: HouseNote?
    private var notes: [HouseNote] { (try? cloud.notes()) ?? [] }
    var body: some View {
        Section("Task note") {
            Picker("Note", selection: $reminder.linkedNoteID) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(notes) { note in Text(note.displayTitle).tag(Optional(note.id)) }
                if let id = reminder.linkedNoteID, !notes.contains(where: { $0.id == id }) {
                    Text("Note not downloaded yet").tag(Optional(id))
                }
            }
            if let id = reminder.linkedNoteID, let note = try? cloud.note(id: id), note.deletedAt == nil {
                Button("Open linked note", systemImage: "note.text") { editing = note }
                Button("Unlink note") { reminder.linkedNoteID = nil }
            }
            Button("Create task note", systemImage: "plus") {
                editing = HouseNote(title: reminder.title, body: "", sourceTaskID: reminder.id)
            }
        }
        .sheet(item: $editing) { NoteEditor(note: $0, onSave: { reminder.linkedNoteID = $0.id }).frame(minWidth: 340, minHeight: 400) }
        .onChange(of: cloud.revision) { _, _ in
            if let id = reminder.linkedNoteID, let note = try? cloud.note(id: id), note.deletedAt != nil {
                reminder.linkedNoteID = nil
            }
        }
    }
}
