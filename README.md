# HouseHippo

A native SwiftUI app for household tasks, meal planning, and groceries on iOS 17+ and macOS 14+.

## Features

- Dashboard with today's tasks, flexible tasks, and completion counts.
- Personal and shared tasks with recurring schedules, completion history, and attached notes.
- Life Management with Waiting For records, dated updates, and flexible task creation.
- Borrowing & Lending grouped by person, with return checkoffs and history.
- Last Time markers with date-only entries, fuzzy elapsed time, and Shared/Sage/Dan filters.
- Inventory collections with independent fields, CSV import, search, and editable records.
- Weekly dinner planning and a categorized grocery checklist.
- iCloud syncing and household sharing.
- Optional Apple Reminders syncing through one configured Mac. Flexible tasks stay in HouseHippo.

## Getting started

Open `HouseHippo.xcodeproj` in Xcode, select the HouseHippo scheme, and choose My Mac or an iPhone simulator.

For your own deployment, configure your development team, bundle identifier, and CloudKit container. Signed builds are required for iCloud features. Keep identifiers and the CloudKit environment consistent across devices.

Household labels filter tasks; they are not privacy boundaries. Household participants can access shared household content, including personally assigned tasks.

## Development

Build without signing:

```sh
xcodebuild -project HouseHippo.xcodeproj -scheme HouseHippo -sdk macosx -derivedDataPath /tmp/HouseHippo-build CODE_SIGNING_ALLOWED=NO build
```

Run focused checks on macOS with Xcode's Swift compiler installed:

```sh
python3 Tests/check_schedule.py
python3 Tests/check_storage.py
python3 Tests/check_inventory.py
python3 Tests/check_sync_policy.py
python3 Tests/check_sync_failures.py
python3 Tests/check_household_repair.py
```

Private backups, databases, build archives, and signing credentials are excluded by `.gitignore`.

## Open an app from a notification

On your iPhone, create a shortcut in Apple's Shortcuts app with an **Open App** action, choose the app (for example, Fertility Friend), and name the shortcut **Open Fertility Friend**. In HouseHippo's notification details, enter that exact name under **When tapped**, use **Test shortcut**, and save. Tapping the scheduled notification opens HouseHippo, then runs the shortcut. You may need to unlock your phone first.

Leave the name blank for the usual HouseHippo behavior. Shortcuts must exist on each receiving iPhone; if you rename one, update the notification. Shortcuts reports missing shortcuts itself. HouseHippo cannot verify that a named shortcut exists or that its actions succeed.

## Inventory imports

Export a table from Numbers as CSV, then open **Inventory → Import CSV**. The first row must contain unique, nonempty column headings. Review the collection name, fields, and first record, then import. Each import creates a separate collection; it does not merge into an existing one. Comma, semicolon, and tab separators, quoted multiline values, UTF-8, and BOM-marked UTF-16 files are supported. Values remain text so catalog numbers and leading zeros stay intact. Short rows receive empty trailing fields; invalid quoting or excess values cause an error before anything is saved.

Open a collection to search all its fields, add records, or edit existing ones. You can also create an empty collection by entering field names, one per line. Waiting For, Borrowing & Lending, Last Time, and Inventory have separate navigation entries. On compact iPhone layouts, additional tabs are available through More.

All Life Management records belong to the shared household, including inventory collections and their imported records. Last Time markers can be labeled Shared, Sage, or Dan. Shared markers appear in both personal filters; labels filter the view and do not restrict household access. Older markers default to Shared.

In each inventory collection, **Main title** chooses which field appears as a record’s heading, or **None** shows only labeled fields. This preference is saved with the collection and shared with the household. The Tasks page has an **Everyone / Sage / Dan / Shared** filter, applied to both active and completed/delayed tasks. Waiting For’s **Add record** button opens a title form.

The main lists use compact rows and inline iPhone navigation titles. Add actions live in toolbars. Editing forms use persistent labels, outlined inputs, and a visible focus ring. Inventory rows show a short preview; opening a record shows every field. The dashboard and Mac sidebar retain their existing layout.
