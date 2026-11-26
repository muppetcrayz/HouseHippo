"""Run HouseHippo regression, XCTest, build, and UI checks with saved reports."""
import argparse
import datetime as dt
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


def stages(root, reports, derived, layer, skip_ui):
    selected = set(layer or ["regression", "native", "build", "ui"])
    if "regression" in selected:
        for check in sorted((root / "Tests").glob("check_*.py")):
            yield check.stem, [sys.executable, str(check)]
    base = ["xcodebuild", "-project", str(root / "HouseHippo.xcodeproj"),
            "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES"]
    if "native" in selected:
        yield "native", base + ["-scheme", "HouseHippoTests", "-destination", "platform=macOS",
                               "-resultBundlePath", str(reports / "native.xcresult"), "test"]
    if "build" in selected:
        for name, destination in [("macos", "generic/platform=macOS"),
                                  ("ios", "generic/platform=iOS Simulator")]:
            yield "build_" + name, base + ["-scheme", "HouseHippo", "-configuration", "Debug",
                                           "-destination", destination, "build"]
    if "ui" in selected and not skip_ui:
        ui_base = [arg for arg in base if arg != "CODE_SIGNING_ALLOWED=NO"]
        yield "ui", ui_base + ["-scheme", "HouseHippoUITests", "-destination", "platform=macOS",
                           "-parallel-testing-enabled", "NO",
                           "-resultBundlePath", str(reports / "ui.xcresult"), "test"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layer", action="append", choices=["regression", "native", "build", "ui"],
                        help="Run only this layer; repeat to select several (default: all).")
    parser.add_argument("--skip-ui", action="store_true", help="Skip UI checks when no GUI/accessibility session is available.")
    parser.add_argument("--results", type=Path, help="New or empty directory for logs, JUnit summary, and xcresult bundles.")
    parser.add_argument("--derived-data", type=Path, default=Path(tempfile.gettempdir()) / "HouseHippo-TestDerivedData")
    parser.add_argument("--list", action="store_true", help="List selected stages without running them.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reports = (args.results or root / "TestResults" / dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")).resolve()
    work = list(stages(root, reports, args.derived_data.resolve(), args.layer, args.skip_ui))
    if args.list:
        print("\n".join(name for name, _ in work))
        return 0
    if not work:
        parser.error("No stages selected.")
    if sys.platform != "darwin" or not all(shutil.which(tool) for tool in ["swift", "xcodebuild", "osacompile"]):
        parser.error("HouseHippo tests require macOS, Python 3.9+, and full Xcode with command-line tools selected.")
    if reports.exists() and any(reports.iterdir()):
        parser.error("--results must be a new or empty directory.")
    reports.mkdir(parents=True, exist_ok=True)
    print(f"Reports: {reports}", flush=True)
    suite = ET.Element("testsuite", name="HouseHippo", tests=str(len(work)))
    failures = []
    started = time.monotonic()
    for name, command in work:
        print(f"\nRunning {name}…", flush=True)
        stage_start = time.monotonic()
        log = reports / (name + ".log")
        with log.open("w") as output:
            output.write("Command: " + repr(command) + "\n\n")
            output.flush()
            result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
        elapsed = time.monotonic() - stage_start
        case = ET.SubElement(suite, "testcase", name=name, classname="HouseHippo", time=f"{elapsed:.3f}")
        if result.returncode:
            failures.append(name)
            tail = "\n".join(log.read_text(errors="replace").splitlines()[-60:])
            ET.SubElement(case, "failure", message=f"Exit {result.returncode}; see {log.name}").text = tail
            print(tail, flush=True)
        ET.SubElement(case, "system-out").text = str(log)
        print(f"{'FAIL' if result.returncode else 'PASS'}: {name} ({elapsed:.1f}s)", flush=True)
        suite.set("failures", str(len(failures)))
        suite.set("time", f"{time.monotonic() - started:.3f}")
        ET.ElementTree(suite).write(reports / "junit.xml", encoding="utf-8", xml_declaration=True)
    print(f"\n{len(work) - len(failures)}/{len(work)} stages passed in {time.monotonic() - started:.1f}s.")
    print(f"Reports: {reports}")
    if failures:
        print("Failed: " + ", ".join(failures), file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nTests interrupted.", file=sys.stderr)
        sys.exit(130)
