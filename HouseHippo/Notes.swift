import SwiftUI

struct TaskNoteSection: View {
    @Binding var reminder: Reminder

    var body: some View {
        Section("Task note") {
            if reminder.taskNote == nil && reminder.linkedNoteID != nil {
                Text("Your task note is downloading. Reopen this task once it arrives.")
                    .foregroundStyle(.secondary)
            } else {
                TextEditor(text: Binding(
                    get: { reminder.taskNote ?? "" },
                    set: { reminder.taskNote = $0 }
                ))
                .frame(minHeight: 160)
                .accessibilityLabel("Task note")
            }
        }
    }
}
