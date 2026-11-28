import SwiftUI
import EventKit
import Combine

@MainActor protocol DashboardCalendarSettingsStorage: AnyObject {
    func read(_ key: String) throws -> Data?
    func put(_ data: Data, key: String) throws
}
extension CloudStore: DashboardCalendarSettingsStorage {}

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
            .init(id: $0.calendarIdentifier, label: "\($0.title) · \($0.source.title)", sourceType: $0.source.sourceType.rawValue)
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
        var sourceType: Int = -1
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
    enum Person: String { case sage, dan }
    private struct SharedSelection: Codable {
        var token = UUID()
        var label: String? // nil is an explicit household-wide clear
        var sourceType: Int?
    }
    private struct LocalLink: Codable { let token: UUID; let calendarID: String }
    @Published private(set) var settingsError: String?
    @Published private(set) var sharedLabels: [String: String] = [:]
    @Published var sageID: String { didSet { selectionChanged(.sage, id: sageID) } }
    @Published var danID: String { didSet { selectionChanged(.dan, id: danID) } }
    private var applyingSettings = false
    private var unresolved = Set<Person>()
    private let household: DashboardCalendarSettingsStorage?
    private var householdObserver: AnyCancellable?
    private static let sageKey = "househippo.calendar.sage"
    private static let danKey = "househippo.calendar.dan"
    private let defaults: UserDefaults
    private let reader: DashboardCalendarReading

    init(defaults: UserDefaults = HouseHippoRuntime.defaults, reader: DashboardCalendarReading? = nil, household: DashboardCalendarSettingsStorage? = nil) {
        self.household = household
        self.reader = reader ?? AppleDashboardCalendarReader()
        self.defaults = defaults
        sageID = defaults.string(forKey: Self.sageKey) ?? ""
        danID = defaults.string(forKey: Self.danKey) ?? ""
        if let cloud = household as? CloudStore {
            householdObserver = cloud.$revision.dropFirst().debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
        }
    }
    private func key(_ person: Person) -> String { "dashboard.calendar." + person.rawValue }
    private func localKey(_ person: Person) -> String { person == .sage ? Self.sageKey : Self.danKey }
    private func selectionChanged(_ person: Person, id: String) {
        guard !applyingSettings else { return }
        guard let household else {
            defaults.set(id, forKey: localKey(person)); refresh(); return
        }
        do {
            let choice = reader.calendars().first { $0.id == id }
            guard id.isEmpty || choice != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
            let selection = SharedSelection(label: choice?.label, sourceType: choice?.sourceType)
            try household.put(JSONEncoder().encode(selection), key: key(person))
            defaults.set(id, forKey: localKey(person))
            try saveLink(person, token: selection.token, id: id)
            settingsError = nil
        } catch {
            applyingSettings = true
            let previous = defaults.string(forKey: localKey(person)) ?? ""
            if person == .sage { sageID = previous } else { danID = previous }
            applyingSettings = false
            settingsError = "Could not save household calendars: " + error.localizedDescription
        }
        refresh()
    }
    private func saveLink(_ person: Person, token: UUID, id: String) throws {
        defaults.set(try JSONEncoder().encode(LocalLink(token: token, calendarID: id)), forKey: key(person) + ".link")
    }
    /// Linking an unmatched shared calendar changes only this device's mapping.
    func link(_ person: Person, to id: String) {
        do {
            guard let data = try household?.read(key(person)),
                  let choice = choices.first(where: { $0.id == id }) else { return }
            let selection = try JSONDecoder().decode(SharedSelection.self, from: data)
            guard selection.label != nil else { return }
            try saveLink(person, token: selection.token, id: choice.id)
            settingsError = nil
        } catch { settingsError = "Could not link calendar: " + error.localizedDescription }
        refresh()
    }
    func isUnresolved(_ person: Person) -> Bool { unresolved.contains(person) }
    func shareExistingSelections() {
        for person in [Person.sage, .dan] {
            do {
                guard try household?.read(key(person)) == nil else { continue }
                let id = person == .sage ? sageID : danID
                if !id.isEmpty { selectionChanged(person, id: id) }
            } catch { settingsError = "Could not read household calendars: " + error.localizedDescription }
        }
    }
    private func applySharedSelections() throws {
        guard let household else { return }
        applyingSettings = true
        defer { applyingSettings = false }
        unresolved = []; sharedLabels = [:]
        for person in [Person.sage, .dan] {
            guard let data = try household.read(key(person)) else {
                // A mapping created for another household is never an initial selection here.
                if defaults.data(forKey: key(person) + ".link") != nil {
                    if person == .sage { sageID = "" } else { danID = "" }
                    defaults.set("", forKey: localKey(person))
                }
                continue
            }
            let selection = try JSONDecoder().decode(SharedSelection.self, from: data)
            var id = ""
            if let label = selection.label {
                sharedLabels[person.rawValue] = label
                let link = defaults.data(forKey: key(person) + ".link").flatMap { try? JSONDecoder().decode(LocalLink.self, from: $0) }
                if let link, link.token == selection.token, choices.contains(where: { $0.id == link.calendarID }) {
                    id = link.calendarID
                } else {
                    let matches = choices.filter { $0.label == label && $0.sourceType == selection.sourceType }
                    if matches.count == 1 { id = matches[0].id; try saveLink(person, token: selection.token, id: id) }
                }
                if id.isEmpty { unresolved.insert(person) }
            }
            if person == .sage { sageID = id } else { danID = id }
            defaults.set(id, forKey: localKey(person))
        }
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
        do { try applySharedSelections() }
        catch { settingsError = "Could not read household calendars: " + error.localizedDescription; return }
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
    @StateObject private var calendar = DashboardCalendarStore(household: CloudStore.shared)
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
            if let error = calendar.settingsError { Text(error).font(.callout).foregroundStyle(.red) }
            if !calendar.authorized {
                Text(calendar.message ?? "Connect your calendars.").font(.callout).foregroundStyle(.secondary)
                Text("Apple requires Full Access to read events. HouseHippo only displays them and never changes your calendars.").font(.caption).foregroundStyle(.secondary)
                Button("Connect Apple Calendar") { Task { await calendar.connect() } }
                    .disabled(calendar.requesting)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                    personCard("Sage", person: .sage, id: calendar.sageID, accent: .teal)
                    personCard("Dan", person: .dan, id: calendar.danID, accent: .indigo)
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
                    if let error = calendar.settingsError { Text(error).foregroundStyle(.red) }
                    Section {
                        Text("Choose one calendar for each person. Both appear on the Dashboard, regardless of the selected task profile. Events are view-only.")
                        Text("Calendar choices sync with your household. Each device still needs access to both calendars in Apple Calendar. If a calendar cannot be matched uniquely, link it on that device.")
                            .foregroundStyle(.secondary)
                    }
                    if calendar.authorized {
                        Section("Household calendars") {
                            calendarPicker("Sage", person: .sage, selection: $calendar.sageID)
                            calendarPicker("Dan", person: .dan, selection: $calendar.danID)
                            Button("Share existing selections") { calendar.shareExistingSelections() }
                            ForEach([DashboardCalendarStore.Person.sage, .dan], id: \.rawValue) { person in
                                if calendar.isUnresolved(person) {
                                    Menu("Link \(person == .sage ? "Sage" : "Dan") on this device") {
                                        ForEach(calendar.choices) { choice in
                                            Button(choice.label) { calendar.link(person, to: choice.id) }
                                        }
                                    }
                                }
                            }
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
    private func calendarPicker(_ title: String, person: DashboardCalendarStore.Person, selection: Binding<String>) -> some View {
        let unresolved = calendar.isUnresolved(person)
        let displayed = Binding(get: { unresolved ? "__household_unavailable__" : selection.wrappedValue }, set: { selection.wrappedValue = $0 })
        return Picker(title, selection: displayed) {
            if unresolved { Text(calendar.sharedLabels[person.rawValue] ?? "Link on this device").tag("__household_unavailable__") }
            Text("Not selected").tag("")
            if !selection.wrappedValue.isEmpty && !calendar.choices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Selected calendar unavailable").tag(selection.wrappedValue)
            }
            ForEach(calendar.choices) { Text($0.label).tag($0.id) }
        }
    }
    private func personCard(_ name: String, person: DashboardCalendarStore.Person, id: String, accent: Color) -> some View {
        let items = calendar.items.filter { $0.calendarID == id }
        return VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline).foregroundStyle(accent)
            if calendar.isUnresolved(person) {
                Text("\(calendar.sharedLabels[person.rawValue] ?? "Household calendar") is unavailable or ambiguous on this device. Add it to Apple Calendar or link it in Calendars.").font(.callout).foregroundStyle(.secondary)
            } else if id.isEmpty {
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
