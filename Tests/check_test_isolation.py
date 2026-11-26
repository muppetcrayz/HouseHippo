"""Verify UI-test isolation is opt-in in Debug and unavailable in Release."""
from pathlib import Path
import os
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = (root / "HouseHippo/HouseHippoApp.swift").read_text()
runtime = source[source.index("enum HouseHippoRuntime {"):source.index("final class NotificationDelegate")]
checks = r'''
let expected = CommandLine.arguments[1] == "true"
precondition(HouseHippoRuntime.isUITesting == expected)
if expected {
    let id = HouseHippoRuntime.testID!.uuidString
    precondition(HouseHippoRuntime.storeDirectory!.lastPathComponent == id)
    precondition(HouseHippoRuntime.storeDirectory!.deletingLastPathComponent().lastPathComponent == "HouseHippo-UITests")
    let key = "isolation-check-" + UUID().uuidString
    let suite = "HouseHippo.UITests." + id
    defer { HouseHippoRuntime.defaults.removePersistentDomain(forName: suite) }
    HouseHippoRuntime.defaults.set("isolated", forKey: key)
    precondition(UserDefaults(suiteName: suite)!.string(forKey: key) == "isolated")
    precondition(UserDefaults.standard.object(forKey: key) == nil)
} else {
    precondition(HouseHippoRuntime.testID == nil)
    precondition(HouseHippoRuntime.storeDirectory == nil)
    precondition(HouseHippoRuntime.defaults === UserDefaults.standard)
}
'''
with tempfile.TemporaryDirectory(prefix="HouseHippo-isolation-checks-") as directory:
    directory = Path(directory)
    script = directory / "Checks.swift"
    script.write_text("import Foundation\n" + runtime + checks)
    environment = {key: value for key, value in os.environ.items() if key != "HOUSEHIPPO_UI_TEST_ID"}
    for mode, flags in [("debug", ["-D", "DEBUG"]), ("release", []),
                        ("ui", ["-D", "DEBUG", "-D", "HOUSEHIPPO_UI_TESTING"])]:
        binary = directory / mode
        subprocess.run(["swiftc", "-module-cache-path", str(directory / "cache"),
                        *flags, str(script), "-o", str(binary)], check=True)
        for test_id in [None, "invalid-identifier", str(uuid.uuid4())]:
            env = dict(environment)
            if test_id is not None:
                env["HOUSEHIPPO_UI_TEST_ID"] = test_id
            expected = mode == "ui" or (mode == "debug" and test_id is not None and test_id != "invalid-identifier")
            subprocess.run([str(binary), str(expected).lower()], check=True, env=env)
print("Test isolation checks passed: Debug UUID opt-in, separate preferences and paths, Release ignores test IDs, UI builds stay isolated even with missing/invalid IDs.")
