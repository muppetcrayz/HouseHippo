import SwiftUI
import EventKit
import Combine

/// This boundary intentionally exposes no calendar mutation operations.
@MainActor protocol DashboardCalendarReading {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func reset()
    func calendars() -> [DashboardCalendarStore.CalendarChoice]
    func items(in day: DateInterval, calendarIDs: Set<String>) -> [DashboardCalendarStore.Item]
}

@MainActor private final class AppleDashboardCalendarReader: DashboardCalendarReading {
    private lazy var events = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    func requestAccess() async throws -> Bool { try await events.requestFullAccessToEvents() }
    func reset() { events.reset() }
    func calendars() -> [DashboardCalendarStore.CalendarChoice] {
        events.calendars(for: .event).map {
            .init(id: $0.calendarIdentifier, label: "\($0.title) · \($0.source.title)")
        }
    }
    func items(in day: DateInterval, calendarIDs: Set<String>) -> [DashboardCalendarStore.Item] {
        let selected = events.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // Never pass nil calendars: that would search every calendar.
        guard !selected.isEmpty else { return [] }
        let predicate = events.predicateForEvents(withStart: day.start, end: day.end, calendars: selected)
        return events.events(matching: predicate).map {
            .init(id: ($0.eventIdentifier ?? $0.calendarItemIdentifier) + ":" + String($0.startDate.timeIntervalSince1970),
                  calendarID: $0.calendar.calendarIdentifier, title: $0.title ?? "Untitled event",
                  start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, canceled: $0.status == .canceled)
        }
    }
}

/// Calendar access is deliberately confined to reads. No EventKit objects reach the UI.
@MainActor final class DashboardCalendarStore: ObservableObject {
    struct CalendarChoice: Identifiable {
        let id: String
        let label: String
    }
    struct Item: Identifiable {
        let id: String
        let calendarID: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        var canceled = false
    }
    @Published private(set) var choices: [CalendarChoice] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var authorized = false
    @Published private(set) var message: String?
    @Published private(set) var requesting = false
    @Published var sageID: String { didSet { defaults.set(sageID, forKey: Self.sageKey); refresh() } }
    @Published var danID: String { didSet { defaults.set(danID, forKey: Self.danKey); refresh() } }
    private static let sageKey = "househippo.calendar.sage"
    private static let danKey = "househippo.calendar.dan"
    private let defaults: UserDefaults
    private let reader: DashboardCalendarReading

    init(defaults: UserDefaults = HouseHippoRuntime.defaults, reader: DashboardCalendarReading? = nil) {
        self.reader = reader ?? AppleDashboardCalendarReader()
        self.defaults = defaults
        sageID = defaults.string(forKey: Self.sageKey) ?? ""
        danID = defaults.string(forKey: Self.danKey) ?? ""
    }
    func connect() async {
        guard !HouseHippoRuntime.isUITesting, !requesting else { return }
        requesting = true
        defer { requesting = false }
        do {
            let granted = try await reader.requestAccess()
            if granted { reader.reset() }
            refresh()
        } catch {
            refresh()
            message = error.localizedDescription
        }
    }
    func refresh(at now: Date = Date(), calendar: Calendar = .current) {
        items = []
        choices = []
        guard !HouseHippoRuntime.isUITesting else { return }
        authorized = reader.authorizationStatus == .fullAccess
        guard authorized else {
            let status = reader.authorizationStatus
            message = status == .denied || status == .restricted
                ? "Calendar access is unavailable. Allow access in system Settings to show today's events."
                : "Connect Apple Calendar to show today's events for Sage and Dan."
            return
        }
        message = nil
        choices = reader.calendars().sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let ids = Set([sageID, danID].filter { !$0.isEmpty })
            .intersection(Set(choices.map(\.id)))
        guard !ids.isEmpty, let day = calendar.dateInterval(of: .day, for: now) else { return }
        items = reader.items(in: day, calendarIDs: ids).filter {
            ids.contains($0.calendarID) && !$0.canceled && $0.start < day.end && $0.end > day.start
        }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct DashboardCalendar: View {
    @StateObject private var calendar = DashboardCalendarStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var configuring = false
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today's calendar", systemImage: "calendar").font(.title3.bold())
                Spacer()
                Button("Calendars", systemImage: "gearshape") { configuring = true }.buttonStyle(.borderless)
            }
            if !calendar.authorized {
                Text(calendar.message ?? "Connect your calendars.").font(.callout).foregroundStyle(.secondary)
                Text("Apple requires Full Access to read events. HouseHippo only displays them and never changes your calendars.").font(.caption).foregroundStyle(.secondary)
                Button("Connect Apple Calendar") { Task { await calendar.connect() } }
                    .disabled(calendar.requesting)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                    personCard("Sage", id: calendar.sageID, accent: .teal)
                    personCard("Dan", id: calendar.danID, accent: .indigo)
                }
            }
        }
        .task { calendar.refresh() }
        .onChange(of: now) { _, value in calendar.refresh(at: value) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { calendar.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in calendar.refresh() }
        .sheet(isPresented: $configuring) {
            NavigationStack {
                Form {
                    Section {
                        Text("Choose one calendar for each person. Both appear on the Dashboard, regardless of the selected task profile. Events are view-only.")
                        Text("Both calendars must be visible in Apple Calendar on this device, including the Google calendar. Choose them separately on each device.")
                            .foregroundStyle(.secondary)
                    }
                    if calendar.authorized {
                        Section("Calendars on this device") {
                            calendarPicker("Sage", selection: $calendar.sageID)
                            calendarPicker("Dan", selection: $calendar.danID)
                        }
                    } else {
                        Section {
                            Text(calendar.message ?? "Connect your calendars.")
                            Button("Connect Apple Calendar") { Task { await calendar.connect() } }.disabled(calendar.requesting)
                        }
                    }
                    Section {
                        Text("Apple requires Full Access permission to read events. HouseHippo only reads today's events from your selected calendars and never creates, edits, or deletes calendar events.")
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Dashboard calendars")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { configuring = false } } }
            }.frame(minWidth: 340, minHeight: 420)
        }
    }
    private func calendarPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Not selected").tag("")
            if !selection.wrappedValue.isEmpty && !calendar.choices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Selected calendar unavailable").tag(selection.wrappedValue)
            }
            ForEach(calendar.choices) { Text($0.label).tag($0.id) }
        }
    }
    private func personCard(_ name: String, id: String, accent: Color) -> some View {
        let items = calendar.items.filter { $0.calendarID == id }
        return VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline).foregroundStyle(accent)
            if id.isEmpty {
                Text("Choose a calendar for \(name). Choose Calendars above to get started.").font(.callout).foregroundStyle(.secondary)
            } else if !calendar.choices.contains(where: { $0.id == id }) {
                Text("Selected calendar unavailable. Check Apple Calendar or choose another calendar.").font(.callout).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("No events today.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.weight(.medium))
                        if item.allDay {
                            Text("All day").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(max(item.start, Calendar.current.startOfDay(for: now)).formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: Calendar.current.isDate(item.end, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if item.id != items.last?.id { Divider() }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}
