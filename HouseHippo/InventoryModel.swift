import Foundation

struct InventoryCollection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var fields: [String]
    var deletedAt: Date?
}

struct InventoryRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var collectionID: UUID
    var values: [String]
    var deletedAt: Date?
    var displayTitle: String { values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "Untitled record" }
}

struct InventoryCSV {
    let fields: [String]
    let rows: [[String]]
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    init(_ text: String) throws {
        var source = text
        if source.first == "\u{FEFF}" { source.removeFirst() }
        // Numbers may use semicolons in locales with a decimal comma.
        let candidates: [Character] = [",", ";", "\t"]
        var counts = [Character: Int](), inQuotes = false
        for character in source {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if character.isNewline { break }
                if candidates.contains(character) { counts[character, default: 0] += 1 }
            }
        }
        let separator = candidates.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
        let best = try Self.parse(source, separator: separator)
        guard let header = best.first else {
            throw ImportError.invalid("The file is empty. Include a header row with your field names.")
        }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names.map { $0.lowercased() }).count == names.count else {
            throw ImportError.invalid("Every column needs a unique, nonempty heading in the first row.")
        }
        fields = names
        rows = try best.dropFirst().enumerated().map { index, row in
            guard row.count <= names.count else { throw ImportError.invalid("Row \(index + 2) has more values than the header. Check its commas and quotation marks.") }
            return row + Array(repeating: "", count: names.count - row.count)
        }
    }
    private static func parse(_ text: String, separator: Character) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false
        var iterator = text.makeIterator()
        func finishField() { row.append(field); field = ""; afterQuote = false }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
        }
        while let character = iterator.next() {
            if quoted {
                if character == "\"" { quoted = false; afterQuote = true }
                else { field.append(character) }
            } else if afterQuote && character == "\"" {
                field.append("\""); quoted = true; afterQuote = false
            } else if character == separator {
                finishField()
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                finishRow()
            } else if afterQuote {
                guard character == " " || character == "\t" else { throw ImportError.invalid("Unexpected text after a closing quote. Check the CSV formatting.") }
            } else if character == "\"" {
                guard field.isEmpty else { throw ImportError.invalid("A quotation mark inside a value must be escaped as two quotation marks.") }
                quoted = true
            } else { field.append(character) }
        }
        guard !quoted else { throw ImportError.invalid("A quoted value is missing its closing quotation mark.") }
        if !field.isEmpty || !row.isEmpty || afterQuote { finishRow() }
        return rows
    }
}
