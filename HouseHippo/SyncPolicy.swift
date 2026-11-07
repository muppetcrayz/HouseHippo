import Foundation

/// Three-way comparison is based on transferable fields, not CloudKit metadata or UI refreshes.
struct AppleSyncPolicy {
    enum Action: String { case acknowledge, push, pull, conflict, missing }
    static func action(base: Data?, local: Data?, remote: Data?) -> Action {
        if local == remote { return .acknowledge }
        guard let base else { return .conflict }
        let localChanged = local != base
        let remoteChanged = remote != base
        if localChanged && remoteChanged { return .conflict }
        if localChanged { return .push }
        if remoteChanged { return .pull }
        return .acknowledge
    }
}

struct AppleSyncSettings: Codable {
    var enabled = false
    var deviceID = ""
    var calendarIDs: [String] = []
    var defaultCalendarID = ""
    var calendarOwners: [String: String] = [:]
    var noteFolderID = ""
    var noteFolderName = ""
}
struct PendingAppleNoteCreation: Codable {
    var value: SyncedNoteValue
    var previouslyVisibleIDs: Set<String>
}
struct AppleSyncCheckpoint: Codable {
    var sourceID: String
    var externalID: String?
    var base: Data?
    var lastCompletion: Date?
    var pendingCompletion: Date?
    var missingSince: Date?
    var outOfScope: Bool?
}
struct AppleSyncConflict: Identifiable, Equatable {
    var id: String
    var title: String
    var explanation: String
    var local: String
    var remote: String
    var canChoose = true
    var allowPush = true
    var allowPull = true
    var localActionTitle: String?
    var remoteActionTitle: String?
}
struct AppleSyncFolder: Identifiable, Sendable { var id: String; var name: String }

struct SyncedNoteValue: Codable, Equatable, Sendable {
    var title: String
    var body: String
    var description: String { title + "\n" + body }
    static func removingTitle(_ text: String, title: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) else { return text }
        return lines.dropFirst().joined(separator: "\n")
    }
    static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    var html: String { "<h1>" + Self.htmlEscape(title) + "</h1><div>" + Self.htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>") + "</div>" }
}
struct SyncedTaskValue: Codable, Equatable {
    var title: String
    var calendarID: String
    var date: Date?
    var allDay: Bool
    var completed: Bool
    var rule: String?
    var description: String {
        title + "\n" + (completed ? "Completed" : "Active") + "\n" + (date?.formatted(date: .abbreviated, time: allDay ? .omitted : .shortened) ?? "No due date") + (rule.map { "\n" + $0 } ?? "")
    }
}
func appleSyncData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
