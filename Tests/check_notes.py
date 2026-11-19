"""Check the actual Apple Notes HTML converter and import script without reading user notes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
notes = (root / 'HouseHippo/Notes.swift').read_text()
model = app[app.index('struct NoteParagraph:'):app.index('struct HouseNote:')]
record = app[app.index('struct AppleNoteImportRecord:'):app.index('struct AppleNoteImportResult')]
reader = notes[notes.index('private enum AppleNotesReader'):notes.rindex('#endif')]
script = notes.split('let source = """')[1].split('"""')[0]
checks = r'''
let parsed = AppleNotesReader.parse("<h1>Home &amp; garden</h1><div>Paragraph<br>Next line</div><ul><li>One<ul><li>Nested &#x1F99B;</li></ul></li><li>Two</li></ul><h2>Next</h2>")
precondition(parsed.map(\.text) == ["Home & garden", "Paragraph", "Next line", "One", "Nested 🦛", "Two", "Next"])
precondition(parsed.map(\.style) == ["h1", "body", "body", "bullet", "bullet", "bullet", "h2"])
precondition(parsed.map(\.depth) == [0, 0, 0, 0, 1, 0, 0])
precondition(AppleNotesReader.parse("").isEmpty)
let restored = try JSONDecoder().decode([NoteParagraph].self, from: JSONEncoder().encode(parsed))
precondition(restored == parsed)
print("Notes checks passed: headings, paragraphs, bullets, nested indentation, entities, emoji and formatting round trip.")
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-notes-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import AppKit\n' + model + record + reader + checks)
    subprocess.run(['swiftc', '-module-cache-path', str(path / 'cache'), str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
    (path / 'import.applescript').write_text(script)
    subprocess.run(['osacompile', '-o', str(path / 'import.scpt'), str(path / 'import.applescript')], check=True)
