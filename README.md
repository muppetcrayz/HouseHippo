# HouseHippo

A native SwiftUI app for household tasks, meal planning, and groceries on iOS 17+ and macOS 14+.

## Features

- Dashboard with today's tasks, flexible tasks, and completion counts.
- Personal and shared tasks with recurring schedules, completion history, and attached notes.
- Life Management with Waiting For records, dated updates, and flexible task creation.
- Borrowing & Lending grouped by person, with return checkoffs and history, plus money balances, list import, and copyable summaries.
- Last Time markers with date-only entries, fuzzy elapsed time, and Shared/Sage/Dan filters.
- Things To Pay for one-off payments with individual amounts, due dates, notes, and paid history.
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

Open a collection to search all its fields, add records, or edit existing ones. You can also create an empty collection by entering field names, one per line. Waiting For, Borrowing & Lending, Last Time, and Inventory have separate navigation entries. On iPhone and iPad they are grouped under the **Life** tab, so the tab bar has five tabs.

All Life Management records belong to the shared household, including inventory collections and their imported records. Last Time markers can be labeled Shared, Sage, or Dan. Shared markers appear in both personal filters; labels filter the view and do not restrict household access. Older markers default to Shared.

In each inventory collection, **Main title** chooses which field appears as a record’s heading, or **None** shows only labeled fields. This preference is saved with the collection and shared with the household. The Tasks page has an **Everyone / Sage / Dan / Shared** filter, applied to both active and completed/delayed tasks. Waiting For’s **Add record** button opens a title form.

Every page uses the dashboard’s layout: a tinted canvas, white rounded cards, section headers with counts, and grids that add columns as the window widens. Filters sit beside each page’s summary line; add actions live in toolbars. Tasks shows Scheduled (grouped into Overdue, Today, Tomorrow, This week, Later) beside Flexible on wide windows. Waiting For shows records beside the selected record’s timeline on wide windows, with an inline box for new updates. Last Time groups markers by age, oldest first, with a **Today** button that resets a marker after you confirm. Inventory collections open as a table on the Mac and iPad, and as cards on iPhone; double-click a row to edit it. Editing forms use persistent labels, outlined inputs, and a visible focus ring. The dashboard and Mac sidebar keep their existing layout.

Borrowing & Lending also includes a **Money** section. Add dated entries per person: positive amounts mean they owe you, negative amounts mean you owe them. Enter repayments with the opposite sign to keep the full history. Balances use exact cents and show what you are owed, what you owe, and the net total. Expand a person’s entries to edit or delete a mistake; use the copy or share button for an itemized summary. **Import list** accepts `5/9 - Farmer’s Market - +24.30` lines, lets you choose the person and year, then previews the recalculated total before saving. Standalone pasted totals are ignored. Money entries sync with the shared household, like other Life records.

Use **Record payment** on a person’s money card for a partial or full payment. The form starts with the full outstanding amount and previews the remaining balance. Settled people automatically disappear from the money list; **Show settled people** reveals their history. A new charge for that person automatically brings them back.

**Things To Pay** appears in the Mac Life Management sidebar and under Life on iPhone/iPad. Track tuition, HOA fees, lessons, or other one-off payments with a description, dollar amount, due date, and optional notes. Entries are grouped into Overdue, Due today, Next 7 days, and Later, with outstanding and upcoming totals. Mark a payment paid to hide it from the active list; **Show paid** reveals history and lets you mark it unpaid again. Each entry is independent, so amounts can vary. These records sync with the shared household.


### Recurring bills and pay periods

In **Life Management → Things To Pay → Recurring bills & pay periods**, keep repeating bills separate from the one-off payment checklist. Recurring bills are assumed paid and have no paid/unpaid status. Add or edit a fixed amount, first occurrence, and monthly or yearly interval. Fixed dates skip months without that day, matching calendar recurrence behavior.

The payday anchor starts at **Friday, November 27, 2026**, repeating every 14 days. Choose another Friday to change it for the household. Each period includes payday Friday through the Thursday before the next payday. Previous/Next browse periods. The budget shows recurring occurrences, unpaid one-off bills due within the period, and their combined total; it does not include earlier overdue one-off bills or paid one-off bills.

To export from Google Calendar on a computer:

1. Open Google Calendar, click the settings gear, and choose **Settings**.
2. Choose **Import & export → Export**.
3. Unzip the downloaded file and find the `.ics` for the bills calendar.
4. In HouseHippo, choose **Import calendar → Choose .ics file**.
5. Review the bills, deselect anything unwanted, enter or confirm each dollar amount, and import.

The import supports fixed-date monthly/yearly series, intervals, end dates/counts, and excluded dates. It preserves titles and descriptions, and proposes an amount only when it finds one unambiguous dollar-prefixed value. Amounts are required before import. Unsupported patterns and series with edited individual occurrences are listed for manual review rather than estimated. Reimporting skips previously imported calendar identities, including deleted bills; it does not update existing bills. This is a file import, not a live Google Calendar connection. Bills and payday settings use the shared household store.

Google’s export instructions: <https://support.google.com/calendar/answer/37111?hl=en>.

Focused validation: `python3 Tests/check_recurring_bills.py`.


### Pay-period budgets and paycheck estimates

In **Recurring bills & pay periods**, **Edit budget & paychecks** recreates the supplied Numbers budget: **Income − bills − additional debt − investments − savings − carryover = free spending**. Bills are calculated automatically from recurring occurrences and unpaid one-off bills due in the selected period. Carryover is an amount set aside (subtracted), matching the sheet; enter a negative amount to release money. The next period includes it in income when **Include previous period’s carryover in income** is enabled (on by default). This matches the sheet’s earlier rollovers; disable it to match the latest rows, which omit the prior-period reference. Debt, investments, savings, carryover, notes, and income entries are saved independently for each period in the shared household store. New periods start with the sheet’s $25 investment allocation, editable to any amount.

Add any number of actual paychecks or other income entries. Alternatively, add Dan or Sage to estimate take-home pay from **hours × hourly rate × take-home percentage**. The editable starting assumptions from the Numbers calculator are Dan: $46.88/hour and 89.574445%; Sage: $50.98/hour and 82.402603%. Hours and actual amounts start blank rather than carrying historical pay into a new period. An actual paycheck can also store hours as a reference. Estimates use a fixed take-home percentage; they do not calculate payroll taxes. Replace estimates with actual take-home amounts when known. Totals sum unrounded estimates before rounding to cents, matching Numbers (so displayed paycheck lines can differ from the total by a cent). Missing income leaves income and free spending unavailable; an explicitly entered zero is valid. Historical rows from the spreadsheet are not automatically imported.


Recurring bills are scoped to **November 1, 2026 through October 31, 2027** (the next November 1 is excluded). Import skips supported series with no occurrences in that window, respecting start dates, end dates, repeat counts, and excluded dates. Previously saved inactive series are automatically omitted from the active list and pay-period totals. They remain archived in storage for duplicate protection; this does not permanently delete records. A series that began years ago remains included if it still has an occurrence in the budget year.


Calendar file reading and parsing run on a cancellable background task, with a progress indicator and a 25 MB file limit. Large previews show 50 bills/messages per page. Saving uses a private Core Data context, checks calendar identities again, commits the selected bills in one transaction, and refreshes the UI once. Recurrence lookup jumps to the requested month for unlimited series and caches displayed pay-period occurrences instead of recalculating on every form update. Finance sheets use grouped, scrollable forms with explicit Mac sizes; input placeholders stay inside the fields, and sheet buttons remain visible while scrolling.

## Notes

Open **Notes** in the Mac sidebar or the iPhone/iPad **Life** tab. Edit notes in one continuous Markdown editor; use **Preview** to view headings and indented bullets. Use `# Heading`, `## Subheading`, and `- Bullet` (indent nested bullets with two spaces). Existing paragraph formatting is converted to Markdown when opened. Notes belong to the shared household and sync through HouseHippo's iCloud store.

On Mac, **Import Apple Notes** reads available notes and shows a selection preview before saving anything. Allow Notes access when macOS prompts. Select the notes you want and choose **Import selected**. This is a one-time copy: future editing happens in HouseHippo. Apple Notes is never modified, and later changes there are not pulled in. Repeating an import skips notes already copied, even if the HouseHippo copy was edited or deleted. Locked/unreadable notes are unavailable; attachments are omitted. Only headings, bullet lists, indentation, and text are retained in the editor; original HTML is retained in storage for recovery. Ordered lists become bullets. Use **Clear notebook… → Clear notebook & allow fresh import** to remove every notebook note for the household and choose a fresh set from Apple Notes. This also removes HouseHippo notebook edits. Task notes are preserved, and Apple Notes stays unchanged. Normal individual deletion still prevents accidental reimport; clearing the notebook explicitly starts a fresh import generation.

Validation: `python3 Tests/check_notes.py` and `python3 Tests/check_storage.py`.

Flexible tasks can be moved to Waiting For using **Convert to Waiting For** in the task editor or the task’s context menu on Tasks and Dashboard. The title becomes the record title and task notes become its first update. The original task leaves the task lists.

Task context menus offer **Move to tomorrow** and, for scheduled repeating tasks, **Move to next repeat**. These postpone the task without marking it complete or adding completion history. The next-repeat action skips to the next scheduled occurrence after today/current due date and preserves the repeat pattern. Date moves (including **Move back to today**) sync to Apple Reminders through the configured sync Mac. Flexible tasks continue to stay in HouseHippo.
