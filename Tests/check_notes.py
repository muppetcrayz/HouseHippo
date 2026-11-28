"""Check the actual Apple Notes HTML converter and import script without reading user notes."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
notes = (root / 'HouseHippo/Notes.swift').read_text()
model = app[app.index('struct NoteParagraph:'):app.index('struct WaitingRecord:')]
record = app[app.index('struct AppleNoteImportRecord:'):app.index('struct AppleNoteImportResult')]
reader = notes[notes.index('private enum AppleNotesReader'):notes.rindex('#endif')]
script = notes.split('let source = """')[1].split('"""')[0]
checks = r'''
precondition(HouseNote.randomItems(in: "- Tea\n- Coffee") == ["Tea", "Coffee"])
precondition(HouseNote.randomItems(in: "\n1. Tea\n\n2. Coffee\n") == ["Tea", "Coffee"])
precondition(HouseNote.randomItems(in: "• Tea\n• Coffee") == ["Tea", "Coffee"])
for invalid in ["", "Tea\nCoffee", "# Drinks\n- Tea", "Intro\n- Tea", "- Tea\n  - Coffee", "- **Tea**", "- [Tea](url)", "- [ ] Tea", "- Tea\n1. Coffee", "- "] {
    precondition(HouseNote.randomItems(in: invalid) == nil, invalid)
}
let listNote = HouseNote(title: "Drinks", body: "", paragraphs: [NoteParagraph(text: "Tea", style: "bullet"), NoteParagraph(text: "Coffee", style: "bullet")])
precondition(listNote.randomItems == ["Tea", "Coffee"])
let parsed = AppleNotesReader.parse("<h1>Home &amp; garden</h1><div>Paragraph<br>Next line</div><ul><li>One<ul><li>Nested &#x1F99B;</li></ul></li><li>Two</li></ul><h2>Next</h2>")
precondition(parsed.map(\.text) == ["Home & garden", "Paragraph", "Next line", "One", "Nested 🦛", "Two", "Next"])
precondition(parsed.map(\.style) == ["h1", "body", "body", "bullet", "bullet", "bullet", "h2"])
precondition(parsed.map(\.depth) == [0, 0, 0, 0, 1, 0, 0])
precondition(AppleNotesReader.parse("").isEmpty)
let note = HouseNote(title: "Test", body: "old body", paragraphs: parsed)
precondition(note.markdownText == "# Home & garden\nParagraph\nNext line\n- One\n  - Nested 🦛\n- Two\n## Next")
let edited = HouseNote(title: "Edited", body: "# Heading\n\n- Bullet")
precondition(edited.markdownText == edited.body)
let restored = try JSONDecoder().decode([NoteParagraph].self, from: JSONEncoder().encode(parsed))
precondition(restored == parsed)
print("Notes checks passed: headings, paragraphs, bullets, nested indentation, entities, emoji and formatting round trip.")
'''
# Opt-in integration check: exercise the real reader, printing counts only.
# This never writes notes or imports into HouseHippo.
if '--live-read' in sys.argv:
    checks += r'''
let records = try AppleNotesReader.read()
let readable = records.filter(\.canImport).count
let failed = records.filter { $0.readError != nil }.count
print("Live read: \(readable) readable, \(records.filter(\.locked).count) locked, \(failed) failed.")
precondition(!records.isEmpty && readable > 0 && failed == 0, "Notes read failed")
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-notes-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import AppKit\n' + model + record + reader + checks)
    subprocess.run(['swiftc', '-module-cache-path', str(path / 'cache'), str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
    (path / 'import.applescript').write_text(script)
    subprocess.run(['osacompile', '-o', str(path / 'import.scpt'), str(path / 'import.applescript')], check=True)
