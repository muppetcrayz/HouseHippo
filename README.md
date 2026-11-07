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
python3 Tests/check_household_repair.py
```

Private backups, databases, build archives, and signing credentials are excluded by `.gitignore`.
