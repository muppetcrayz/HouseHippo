# HouseHippo tests

Run the complete local suite from the repository root on macOS with full Xcode selected and Python 3.9+:

```sh
python3 Tests/run_all.py
```

The runner executes every layer, continues after failures, and exits nonzero if any stage fails. It saves separate logs, a stage-level JUnit XML summary, and native/UI `.xcresult` bundles under a new `TestResults/<timestamp>/` directory. Open an `.xcresult` in Xcode to see individual test results, coverage, and UI failure screenshots/accessibility trees. The JUnit file describes stages; individual XCTest cases are in the Xcode bundles.

UI tests require an unlocked macOS desktop and permission for Xcode's test runner to use Accessibility/automation if macOS prompts. They launch and interact with a separate instance of HouseHippo. CI runs the other layers with `--skip-ui` because a hosted runner does not provide a dependable interactive desktop. UI tests are macOS tests; iOS currently has compile validation and shared-model regression coverage.

## Layers

| Layer | Coverage |
| --- | --- |
| Native XCTest | Grocery classification and legacy parsing; meal week/date keys across DST and year changes; Last Time dates and ownership; sync decision combinations; notification assignment; waiting updates; CSV and money validation; monthly/daily/weekly recurrence; completion/undo; editor deferrals |
| Native SQLite integration | Empty offline stores, durable reopen, grocery edits/deletions/migration, stale writes, inventory import rollback and schema validation, Waiting For conversion, backup transfer/idempotence/invalid input, notebook/task-note independence |
| Focused regressions | All `check_*.py` scripts, including 67 imported recurrence fixtures with independent calendar expectations, scheduler edge cases, data migration/recovery, household repair, notification callback threading, sync failure/retry behavior, AppleScript compilation, notes formatting, payment/budget calculations |
| App builds | Unsigned Debug macOS and iOS Simulator builds of the actual app target |
| macOS UI | Navigation, grocery add/check/persistence, Waiting For create/cancel/empty-title validation, notebook create/persistence, inventory collection creation; borrowing/returning; Last Time marker persistence; payment validation/persistence |

The unhosted `HouseHippoTests` target compiles the actual application sources with `HOUSEHIPPO_TESTING`, excluding only the SwiftUI app entry point. This avoids launching the normal app or initializing its live store while testing. New app source files must also be added to the native test target in Xcode. The existing Python checks remain for their deeper scenario coverage.

## Focused runs

```sh
python3 Tests/run_all.py --layer native
python3 Tests/run_all.py --layer regression
python3 Tests/run_all.py --layer build
python3 Tests/run_all.py --layer ui
python3 Tests/run_all.py --skip-ui
python3 Tests/run_all.py --list
python3 Tests/check_schedule.py
```

Repeat `--layer` to combine layers. Use `--results /path/to/new-directory` to choose the report location and `--derived-data /path/to/cache` to reuse a build cache. The results directory must be new or empty so a previous run cannot be mistaken for the current one.

In Xcode, select **HouseHippoTests** or **HouseHippoUITests**, select **My Mac**, and choose **Product → Test**. Both shared schemes enable code coverage. Equivalent commands:

```sh
xcodebuild -project HouseHippo.xcodeproj -scheme HouseHippoTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project HouseHippo.xcodeproj -scheme HouseHippoUITests -destination 'platform=macOS' test
```

Run just the random-note feature checks:

```sh
xcodebuild -project HouseHippo.xcodeproj -scheme HouseHippoTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HouseHippoTests/RandomNoteListTests test
xcodebuild -project HouseHippo.xcodeproj -scheme HouseHippoUITests -destination 'platform=macOS' -only-testing:HouseHippoUITests/HouseHippoUITests/testRandomNotePickingPreservesListUntilWholeNoteIsEdited test
```

These cover plain bullet/numbered lists, empty or formatted content, imported list paragraphs, repeated picking without removal, persistence after relaunch, and changing eligibility by editing the whole note.

## Data isolation

Native storage tests use unique temporary SQLite directories and unique preference suites with CloudKit disabled. They never call `CloudStore.shared` or launch the app.

The UI scheme uses an ad-hoc-signed `UITesting` configuration with the separate `com.danturner.HouseHippo.UITesting` app identifier, so it does not launch or terminate the installed production app. No developer signing credentials are needed. UI tests launch this Debug-based build with a unique `HOUSEHIPPO_UI_TEST_ID` UUID. The app uses a temporary `HouseHippo-UITests/<UUID>` database and `HouseHippo.UITests.<UUID>` preferences; legacy preferences are excluded. Relaunching within a test retains the same UUID to verify persistence. Apple sync, notification scheduling/registration, and CloudKit are disabled. Each test refuses to interact unless the app displays its isolated-household marker. Release builds ignore the environment variable; `check_test_isolation.py` verifies both compile modes and missing/invalid IDs. The `UITesting` configuration always isolates storage, generating a fresh UUID if the environment ID is missing or invalid. Test stores are temporary; each subsequent test uses a new UUID.

The AppleScript checks compile against installed Notes terminology without reading/writing personal notes. They can fail inside a restricted sandbox with XPC/class-name errors; run from a normal macOS terminal to verify. `check_notes.py --live-read` is an explicit optional read of real Apple Notes and is never included by the suite.

## Calendar integration coverage

`DashboardCalendarTests` uses an injected read-only fake; it never requests system permissions or reads personal events. It covers the two-calendar allowlist, empty/missing selections, permission grant/denial/error/revocation, local preference persistence, canceled events, overnight and all-day events, midnight rollover, and 23/25-hour DST days. Household tests cover different local IDs, shared selection changes and clears, ambiguous/missing matches, persistent local links, explicit legacy migration, read/decode failures, and household switching. A SQLite integration test verifies that selections use household entries while calendar identifiers stay local. The macOS UI suite verifies the calendar setup sheet and dismissal in an isolated household. Live Apple/Google account delivery and OS permission dialogs remain signed-device checks.

## Signed-device integration checks

These remain manual because they require real entitlements, accounts, permissions, and two devices. Use a disposable test household and Reminders lists:

1. Create a household invitation on one signed device, accept on another account, and verify task/note/grocery/meal creation, edits, and deletion in both directions.
2. Disconnect one device, edit separate records on both devices, reconnect, and verify both changes survive. Reopen both apps and verify persistence.
3. On the designated sync Mac, enable Reminders sync for disposable lists. Test add/edit/complete/delete from both apps, concurrent edit/conflict resolution, list movement, denied access, and retry after failure. Confirm no duplicate writes after restarting.
4. On iPhone, enable notifications for each person and Shared. Verify foreground/background delivery, task silence, completion/disable cancellation, future starts, and notification-to-Shortcut behavior.
5. Export a backup from a test household, import into a fresh test installation, repeat the import, and verify records and independent edits survive.
6. On iPhone/iPad, exercise navigation, forms, keyboard dismissal, task filters, inventory table/card layouts, and Dynamic Type.

No automated result should be interpreted as verifying live CloudKit delivery, Apple service permissions, physical-device notifications, or every visual layout. Coverage reports are diagnostic; no arbitrary percentage threshold is enforced.
