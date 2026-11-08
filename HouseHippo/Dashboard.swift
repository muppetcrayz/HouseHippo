import SwiftUI
import Combine

struct HomeDashboard: View {
    @EnvironmentObject private var store: ReminderStore
    @ObservedObject private var cloud = CloudStore.shared
    @AppStorage("househippo.person") private var person = Reminder.Owner.me.rawValue
    @State private var now = Date()
    @State private var search = ""
    @State private var editing: Reminder?
    @State private var randomPick: Reminder?
    @State private var connections = false
    var navigate: (Int) -> Void
    private var owner: Reminder.Owner { Reminder.Owner(rawValue: person) ?? .me }
    private var personalTasks: [Reminder] {
        store.reminders.filter { !$0.isNotification && ($0.owner == .shared || $0.owner == owner) }
    }
    private var visible: [Reminder] {
        personalTasks.filter { search.isEmpty || ($0.title + " " + $0.list).localizedCaseInsensitiveContains(search) }
    }
    private var done: Int { personalTasks.filter { $0.lastCompleted.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }.count }
    private var dinner: String {
        (try? cloud.read(MealWeek.storageKey(for: now))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: now)
        return hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
    }
    var body: some View {
        // ReminderStore already publishes tasks in display order. Compute each pool once per render.
        let tasks = visible
        let today = tasks.filter { $0.isDueToday(at: now) }
        let flexible = tasks.filter { $0.isAvailableFlexible(at: now) }
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    HStack(spacing: 10) {
                        metric("Today", value: today.count, icon: "sun.max", color: .teal)
                        metric("Flexible", value: flexible.count, icon: "leaf", color: .orange)
                        metric("Done today", value: done, icon: "checkmark.circle", color: .green)
                    }
                    taskBoard("Today's Tasks", icon: "sun.max", tasks: today, accent: .teal, todayRandom: true)
                    taskBoard("Flexible Tasks", icon: "leaf", tasks: flexible, accent: .orange)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                        dinnerCard
                    }
                }.padding(20)
            }
            .background(Color.primary.opacity(0.025))
            .navigationTitle("Dashboard")
            .searchable(text: $search, prompt: "Find a task")
            .sheet(item: $editing) { ReminderEditor(reminder: $0).frame(minWidth: 340, minHeight: 500) }
            .sheet(item: $randomPick) { RandomPickSheet(task: $0) }
            .sheet(isPresented: $connections) {
                NavigationStack {
                    ScrollView { CloudStatusView().padding(24) }
                        .navigationTitle("Connections")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { connections = false } } }
                }.frame(minWidth: 340, minHeight: 360)
            }
            .task { do { try cloud.migrateMealDates() } catch { cloud.report(error) } }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .onAppear { now = Date() }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) { welcome; Spacer(minLength: 20); profile }
                VStack(alignment: .leading, spacing: 12) { welcome; profile }
            }
            HStack(spacing: 10) {
                Button { connections = true } label: {
                    Label(cloud.status, systemImage: "icloud").font(.caption).lineLimit(1)
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add task", systemImage: "plus") {
                    var task = Reminder(title: "", message: "", date: Date().addingTimeInterval(3600), frequency: .once)
                    task.kind = .task; task.owner = owner
                    editing = task
                }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(greeting), \(owner.displayName)").font(.system(.largeTitle, design: .rounded).bold())
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day())).foregroundStyle(.secondary)
        }
    }
    private var profile: some View {
        Picker("Viewing as", selection: $person) {
            Text("Sage").tag(Reminder.Owner.me.rawValue)
            Text("Dan").tag(Reminder.Owner.husband.rawValue)
        }.pickerStyle(.segmented).frame(width: 170)
    }
    private func metric(_ title: String, value: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value, format: .number).font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private func taskBoard(_ title: String, icon: String, tasks: [Reminder], accent: Color, todayRandom: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { boardTitle(title, icon: icon, count: tasks.count, accent: accent); Spacer(); randomButton(tasks, title: title, todayRandom: todayRandom) }
                VStack(alignment: .leading, spacing: 8) { boardTitle(title, icon: icon, count: tasks.count, accent: accent); randomButton(tasks, title: title, todayRandom: todayRandom) }
            }
            if tasks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(accent)
                    Text(search.isEmpty ? "All clear here. Your other tasks are in Tasks." : "No matching tasks in this list.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(tasks) { task in DashboardTaskCard(task: task, accent: accent, open: { editing = task }) }
                }
            }
        }
    }
    private func boardTitle(_ title: String, icon: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(accent)
            Text(title).font(.title3.bold())
            Text(count, format: .number).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(accent.opacity(0.1), in: Capsule())
        }
    }
    private func randomButton(_ tasks: [Reminder], title: String, todayRandom: Bool) -> some View {
        Button("Random pick", systemImage: "dice") {
            randomPick = tasks.filter { !todayRandom || $0.isEligibleForTodayRandom() }.randomElement()
        }
            .buttonStyle(.bordered)
            .disabled(!tasks.contains { !todayRandom || $0.isEligibleForTodayRandom(at: now) })
            .accessibilityLabel("Pick a random task from " + title)
    }
    private var dinnerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tonight's dinner", systemImage: "fork.knife").font(.headline)
            Text(dinner.isEmpty ? "What sounds good tonight?" : dinner).font(.callout).foregroundStyle(dinner.isEmpty ? .secondary : .primary).lineLimit(3)
            Button("Plan meals", systemImage: "arrow.right") { navigate(5) }.buttonStyle(.borderless)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading).padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

}

/// A random pick shows only the task's name and a way to finish it; full details stay in the editor.
struct RandomPickSheet: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    let task: Reminder
    @State private var completing = false
    var body: some View {
        VStack(spacing: 20) {
            Label("Random pick", systemImage: "dice").font(.headline).foregroundStyle(.teal)
            Text(task.title).font(.system(.title, design: .rounded).bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                completing = true
                Task {
                    // Complete the latest saved version in case it synced while the sheet was open.
                    await store.complete(store.reminders.first { $0.id == task.id } ?? task)
                    dismiss()
                }
            } label: {
                Label("Mark done", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
            .disabled(completing)
            Button("Not now") { dismiss() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320, maxWidth: 420)
        .presentationDetents([.medium])
    }
}

private struct DashboardTaskCard: View {
    @EnvironmentObject private var store: ReminderStore
    let task: Reminder
    let accent: Color
    let open: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button { Task { await store.complete(task) } } label: {
                Image(systemName: "circle").font(.title2).foregroundStyle(accent)
                    .frame(width: 44).frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Complete " + task.title)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Text(task.summary).font(.caption).foregroundStyle(task.isOverdue() ? .red : .secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(task.list).lineLimit(1)
                        Text("·")
                        Text(task.owner.displayName)
                    }.font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading).padding(.vertical, 10).padding(.trailing, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)) }
        .contextMenu {
            if task.canMoveToTomorrow {
                Button("Move to tomorrow", systemImage: "calendar.badge.clock") { Task { await store.moveToTomorrow(task) } }
            }
            Button("Delete task", role: .destructive) { Task { await store.delete(task) } }
        }
    }
}
