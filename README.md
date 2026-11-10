# HouseHippo

A native SwiftUI app for household tasks, meal planning, and groceries on iOS 17+ and macOS 14+.

## Features

- Dashboard with today's tasks, flexible tasks, and completion counts.
- Personal and shared tasks with recurring schedules, completion history, and attached notes.
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
python3 Tests/check_sync_policy.py
python3 Tests/check_sync_failures.py
python3 Tests/check_household_repair.py
```

Private backups, databases, build archives, and signing credentials are excluded by `.gitignore`.

## Open an app from a notification

On your iPhone, create a shortcut in Apple's Shortcuts app with an **Open App** action, choose the app (for example, Fertility Friend), and name the shortcut **Open Fertility Friend**. In HouseHippo's notification details, enter that exact name under **When tapped**, use **Test shortcut**, and save. Tapping the scheduled notification opens HouseHippo, then runs the shortcut. You may need to unlock your phone first.

Leave the name blank for the usual HouseHippo behavior. Shortcuts must exist on each receiving iPhone; if you rename one, update the notification. Shortcuts reports missing shortcuts itself. HouseHippo cannot verify that a named shortcut exists or that its actions succeed.
