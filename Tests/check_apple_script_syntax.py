"""Compile constant AppleScripts and test local variable binding without executing import/sync handlers or accessing Apple records."""
from pathlib import Path
import subprocess, tempfile, re
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='HouseHippo-AppleScript-checks-') as directory:
    directory=Path(directory)
    paths=[]
    # The Apple Notes import script is a Swift multi-line string in AppleNotesReader.read().
    body=(root/'HouseHippo/Notes.swift').read_text().split('static func read()',1)[1]
    match=re.search(r'let source = """\n(.*?)\n( *)"""', body, re.DOTALL)
    assert match, 'Could not find the Apple Notes import script in Notes.swift'
    indent=match.group(2)
    lines=match.group(1).split('\n')
    assert all(not line.strip() or line.startswith(indent) for line in lines), 'Unexpected script indentation'
    assert '\\' not in match.group(1), 'Escapes in the Swift string need handling before compiling the script'
    source='\n'.join(line[len(indent):] for line in lines)
    assert not re.search(r'set\s+plaintext\s+to', source, re.IGNORECASE), 'Local variable collides with the read-only Notes plaintext property'
    path=directory/'AppleNotesImport.applescript';path.write_text(source);paths.append(str(path))
    code=r'''
import Foundation
import AppKit
for path in CommandLine.arguments.dropFirst() {
    let source = try String(contentsOfFile:path,encoding:.utf8)
    guard let script=NSAppleScript(source:source) else { fatalError("Could not create script") }
    var error:NSDictionary?
    guard script.compileAndReturnError(&error) else { print("Script syntax failed for " + path + ": " + (error?.description ?? "unknown error")); exit(1) }
}
// Exercise only variable binding under Notes terminology. No tell block or Apple record access.
let bindingCheck = """
using terms from application "Notes"
    on testBindings()
        local hhNotePlainValue, hhNoteHTMLValue
        set hhNotePlainValue to ""
        set hhNoteHTMLValue to ""
        set hhNotePlainValue to "Example text"
        return hhNotePlainValue
    end testBindings
end using terms from
return testBindings()
"""
let bindingScript = NSAppleScript(source: bindingCheck)!
var bindingError: NSDictionary?
let bindingResult = bindingScript.executeAndReturnError(&bindingError)
guard bindingError == nil, bindingResult.stringValue == "Example text" else {
    print("Notes variable binding failed: " + (bindingError?.description ?? "unexpected result")); exit(1)
}
print("AppleScript syntax and local-variable binding checks passed. No import/sync handlers executed; no Apple records accessed.")
'''
    script=directory/'Check.swift';script.write_text(code)
    subprocess.run(['swift','-module-cache-path',str(directory/'cache'),str(script),*paths],check=True)
