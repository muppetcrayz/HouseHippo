"""Exercise the inventory CSV parser without the UI or a live household store."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / 'HouseHippo/InventoryModel.swift').read_text()
checks = r'''
@main struct InventoryChecks {
    static func main() throws {
        let csv = try InventoryCSV("\u{FEFF}Title,Artist,Catalog,Notes\r\n\"Record, One\",Artist,0012,\"First line\nSecond line with \"\"quotes\"\"\"\r\nRecord Two,Other,0003,\r\n\r\n")
        precondition(csv.fields == ["Title", "Artist", "Catalog", "Notes"])
        precondition(csv.rows.count == 2)
        precondition(csv.rows[0] == ["Record, One", "Artist", "0012", "First line\nSecond line with \"quotes\""])
        precondition(csv.rows[1] == ["Record Two", "Other", "0003", ""])
        let animals = try InventoryCSV("Name;Species;Location\nHippo;Hippopotamus;Shelf\n")
        precondition(animals.fields == ["Name", "Species", "Location"])
        precondition(animals.rows[0] == ["Hippo", "Hippopotamus", "Shelf"])
        let tabs = try InventoryCSV("Name\tNotes\nHippo\t\"Soft\tand fluffy\"\n")
        precondition(tabs.rows == [["Hippo", "Soft\tand fluffy"]])
        let shortRow = try InventoryCSV("Title,Artist,Year\nA record\n")
        precondition(shortRow.rows == [["A record", "", ""]])
        let headerOnly = try InventoryCSV("Name,Notes")
        precondition(headerOnly.fields == ["Name", "Notes"] && headerOnly.rows.isEmpty)
        let single = try InventoryCSV("Name\nHippo\n")
        precondition(single.rows == [["Hippo"]])
        for invalid in ["", "Name,name\nA,B", "Name,\nA,B", "Name,Notes\nA,B,C", "Name,Notes\nA,\"unclosed", "Name,Notes\nA,\"quoted\"oops", "Name,Notes\nA,bad\"quote"] {
            do { _ = try InventoryCSV(invalid); preconditionFailure("Accepted invalid CSV: \(invalid)") }
            catch is InventoryCSV.ImportError {}
        }
        var collection = InventoryCollection(name: "Records", fields: ["Catalog", "Title", "Artist"])
        let record = InventoryRecord(collectionID: collection.id, values: ["0012", "A record", "Artist"])
        precondition(collection.title(for: record) == "0012")
        collection.titleFieldIndex = 1
        precondition(collection.title(for: record) == "A record")
        collection.titleFieldIndex = -1
        precondition(collection.title(for: record) == nil && collection.effectiveTitleFieldIndex == nil)
        collection.titleFieldIndex = 2
        var blankTitle = record; blankTitle.values[2] = ""
        precondition(collection.title(for: blankTitle) == "Untitled record")
        let legacy = try JSONDecoder().decode(InventoryCollection.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Records\",\"fields\":[\"Catalog\",\"Title\"]}".utf8))
        precondition(legacy.titleFieldIndex == nil && legacy.title(for: record) == "0012")
        print("Inventory CSV checks passed: BOM, CRLF, multiline fields, escaped quotes, leading zeros, semicolon/tab separators, short rows, header-only files, and invalid input rejection.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-inventory-checks-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(model + checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
