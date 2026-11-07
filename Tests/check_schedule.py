"""Run focused checks against the scheduler source with the installed Swift compiler."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "HouseHippo/HouseHippoApp.swift").read_text()
model = source[source.index("struct Reminder:"):source.index("final class NotificationDelegate")]
model += "\n" + (root / "HouseHippo/Recurrence.swift").read_text()
method = source[source.index("    private func upcoming"):source.index("\n}\n\n@main")].replace("private func upcoming", "func upcoming")
checks = 'let calendar = Calendar.current\nlet oldDate = calendar.date(byAdding: .year, value: -10, to: Date())!\nfor unit in Reminder.IntervalUnit.allCases {\n    let reminder = Reminder(title: "Test", message: "", date: oldDate, frequency: .custom, interval: 3, unit: unit)\n    let dates = upcoming(reminder, count: 20)\n    precondition(dates.count == 20)\n    precondition(dates.allSatisfy { $0 > Date() })\n    precondition(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })\n}\nlet future = Date().addingTimeInterval(3600)\nlet one = upcoming(Reminder(title: "Future", message: "", date: future, frequency: .custom), count: 1)\nprecondition(one == [future])\nlet january = calendar.date(from: DateComponents(year: 2030, month: 1, day: 31, hour: 9))!\nlet months = upcoming(Reminder(title: "Month end", message: "", date: january, frequency: .custom, unit: .months), count: 3)\nprecondition(months.map { calendar.component(.day, from: $0) } == [31, 28, 31])\nprint("Schedule checks passed: past anchors, all interval units, ordering, future starts, and month ends.")\n'
checks += r'''
let jan = calendar.date(from: DateComponents(year: 2030, month: 1, day: 12))!
var flexible = Reminder(title: "Filter", message: "", date: jan, frequency: .flexible)
precondition(calendar.component(.month, from: flexible.dueMonth) == 1)
flexible.lastCompleted = jan
precondition(calendar.component(.month, from: flexible.dueMonth) == 2)
precondition(calendar.component(.day, from: flexible.dueMonth) == 1)
let feb28 = calendar.date(from: DateComponents(year: 2030, month: 2, day: 28, hour: 23))!
let mar1 = calendar.date(from: DateComponents(year: 2030, month: 3, day: 1))!
precondition(!flexible.isOverdue(at: feb28))
precondition(flexible.isOverdue(at: mar1))
flexible.interval = 3
precondition(calendar.component(.month, from: flexible.dueMonth) == 4)
flexible.lastCompleted = calendar.date(from: DateComponents(year: 2030, month: 12, day: 31))!
precondition(calendar.component(.month, from: flexible.dueMonth) == 3)
precondition(calendar.component(.year, from: flexible.dueMonth) == 2031)
let encoded = try JSONEncoder().encode(flexible)
let decoded = try JSONDecoder().decode(Reminder.self, from: encoded)
precondition(decoded.history == flexible.history && decoded.dueMonth == flexible.dueMonth)
print("Flexible month checks passed: due month, grace period, quarterly repeats, year rollover and persistence.")
'''
checks += r'''
var silent = Reminder(title: "Silent task", message: "", date: Date(), frequency: .daily)
precondition(!silent.shouldNotify)
let legacyData = try JSONEncoder().encode(silent)
let legacy = try JSONDecoder().decode(Reminder.self, from: legacyData)
precondition(legacy.kind == nil && !legacy.shouldNotify)
silent.kind = .task
precondition(!silent.shouldNotify)
silent.kind = .notification
precondition(silent.shouldNotify)
silent.enabled = false
precondition(!silent.shouldNotify)
silent.enabled = true
silent.completed = true
precondition(!silent.shouldNotify)
print("Notification separation checks passed: legacy and explicit tasks stay silent; only active notifications send alerts.")
'''
checks += r'''
let nov5 = calendar.date(from: DateComponents(year: 2030, month: 11, day: 5))!
let afternoon = calendar.date(byAdding: .hour, value: 15, to: nov5)!
let nov6 = calendar.date(byAdding: .day, value: 1, to: nov5)!
var allDayTask = Reminder(title: "All day", message: "", date: nov5, frequency: .once)
precondition(allDayTask.isAllDay) // Legacy midnight values stay compatible.
precondition(!allDayTask.isOverdue(at: afternoon))
precondition(allDayTask.isOverdue(at: nov6))
precondition(allDayTask.isDueToday(at: afternoon))
precondition(!allDayTask.isDueToday(at: nov6))
allDayTask.allDay = false // Legacy imports marked midnight as timed; it is still an all-day task.
precondition(allDayTask.isAllDay && !allDayTask.isOverdue(at: afternoon))
allDayTask.date = calendar.date(byAdding: .hour, value: 9, to: nov5)!
precondition(allDayTask.isOverdue(at: afternoon))
allDayTask.hasDueDate = false
precondition(!allDayTask.isDueToday(at: afternoon) && !allDayTask.isOverdue(at: afternoon))
var tomorrow = Reminder(title: "Tomorrow", message: "", date: nov6, frequency: .once)
precondition(!tomorrow.isDueToday(at: afternoon))
tomorrow.date = calendar.date(byAdding: .day, value: -1, to: nov5)!
precondition(!tomorrow.isDueToday(at: afternoon))
var monthlyTask = Reminder(title: "Monthly", message: "", date: nov5, frequency: .flexible)
precondition(!monthlyTask.isDueToday(at: afternoon))
precondition(monthlyTask.isAvailableFlexible(at: afternoon))
precondition(!monthlyTask.isDueToday(at: calendar.date(byAdding: .month, value: 1, to: afternoon)!))
monthlyTask.completed = true
precondition(!monthlyTask.isDueToday(at: afternoon))
precondition(!Reminder.shouldImport(completed: true, hasRecurrence: false))
precondition(Reminder.shouldImport(completed: true, hasRecurrence: true))
precondition(Reminder.shouldImport(completed: false, hasRecurrence: false))
precondition(Reminder.shouldImport(completed: false, hasRecurrence: true))
print("Today checks passed: all-day grace period, legacy midnight, timed deadlines, dashboard dates, undated tasks and completed import filtering.")
'''
checks += r'''
var undated = Reminder(title: "Whenever", message: "", date: .distantPast, frequency: .anytime)
undated.hasDueDate = false
precondition(undated.isUnscheduled)
precondition(undated.summary == "Flexible · no due date")
precondition(!undated.isDueToday(at: afternoon) && !undated.isOverdue(at: afternoon))
precondition(!undated.shouldNotify)
undated.frequency = .once // Older explicit undated imports use the same display and behavior.
precondition(undated.summary == "Flexible · no due date")
let undatedCopy = try JSONDecoder().decode(Reminder.self, from: JSONEncoder().encode(undated))
precondition(undatedCopy.hasDueDate == false && undatedCopy.isUnscheduled)
print("Undated checks passed: no invented deadline, flexible display, legacy imports, no alerts and persistence.")
'''
checks += r'''
let tiedA = Reminder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Same", message: "", date: nov5, frequency: .once)
let tiedB = Reminder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Same", message: "", date: nov5, frequency: .once)
precondition([tiedB, tiedA].sorted(by: Reminder.orderedBefore) == [tiedA, tiedB])
precondition([tiedA, tiedB].sorted(by: Reminder.orderedBefore) == [tiedA, tiedB])
print("Stable ordering checks passed: equal-date and equal-title tasks keep their order across reloads.")
'''
checks += r'''
var personal = Reminder(title: "Daily", message: "", date: nov5, frequency: .daily)
personal.list = "Personal Recurring"
personal.applyHouseholdListRules()
precondition(personal.list == "Personal" && personal.owner == .me && personal.frequency == .daily)
let personalOnce = personal
personal.applyHouseholdListRules()
precondition(personal == personalOnce)
var dans = Reminder(title: "Dan's task", message: "", date: nov5, frequency: .weekly)
dans.list = "Personal Recurring"
dans.owner = .husband
dans.applyHouseholdListRules(personalOwner: .husband)
precondition(dans.list == "Personal" && dans.owner == .husband && dans.frequency == .weekly)
var chores = Reminder(title: "Weekly chore", message: "", date: nov5, frequency: .weekly)
chores.list = "General Recurring"
chores.owner = .me
chores.applyHouseholdListRules()
precondition(chores.list == "Chores" && chores.owner == .shared && chores.frequency == .weekly)
for list in ["Errands", "One-Off General Tasks", "One-Off Personal Tasks"] {
    var task = Reminder(title: "Flexible", message: "", date: afternoon, frequency: .once)
    task.list = list
    task.applyHouseholdListRules()
    precondition(task.isUnscheduled && !task.isDueToday(at: afternoon) && !task.isOverdue(at: nov6))
    precondition(task.owner == (list == "One-Off Personal Tasks" ? .me : .shared))
}
var lastTime = Reminder(title: "Quarterly", message: "", date: nov5, frequency: .flexible, interval: 3)
lastTime.list = "One-Off General Tasks"
lastTime.applyHouseholdListRules()
precondition(lastTime.frequency == .flexible && lastTime.interval == 3)
print("Household list checks passed: names, personal ownership, Dan's imports, shared chores, flexible lists, LastTime preservation and idempotent correction.")
'''
checks += r'''
for frequency in [Reminder.Frequency.once, .daily, .weekly, .monthly, .custom] {
    var task = Reminder(title: "All day", message: "", date: nov5, frequency: frequency)
    task.allDay = false // Repair the interpretation of earlier midnight imports without rewriting records.
    let midnight = nov5.formatted(date: .omitted, time: .shortened)
    precondition(task.isAllDay && !task.summary.contains(midnight))
    task.allDay = true
    task.date = afternoon
    precondition(!task.summary.contains(afternoon.formatted(date: .omitted, time: .shortened)))
}
var midnightAlert = Reminder(title: "Explicit alert", message: "", date: nov5, frequency: .daily)
midnightAlert.kind = .notification
precondition(!midnightAlert.isAllDay)
precondition(midnightAlert.summary.contains(nov5.formatted(date: .omitted, time: .shortened)))
print("All-day display checks passed: one-off, daily, weekly, monthly, custom, legacy midnight and separate timed alerts.")
'''
checks += r'''
let sunday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
let tuesday = calendar.date(byAdding: .day, value: 2, to: sunday)!
let thursday = calendar.date(byAdding: .day, value: 4, to: sunday)!
let nextSunday = calendar.date(byAdding: .day, value: 7, to: sunday)!
var litter = Reminder(title: "Litter boxes", message: "", date: sunday, frequency: .weekly)
litter.selectedWeekdays = [5, 1, 3, 3, 0, 8]
litter.allDay = true
precondition(litter.weekdays == [1, 3, 5])
precondition(litter.nextWeeklyAfterCompletion(at: sunday.addingTimeInterval(12 * 3600)) == tuesday)
litter.date = tuesday
precondition(litter.nextWeeklyAfterCompletion(at: tuesday.addingTimeInterval(12 * 3600)) == thursday)
litter.date = thursday
precondition(litter.nextWeeklyAfterCompletion(at: thursday.addingTimeInterval(12 * 3600)) == nextSunday)
litter.date = sunday
precondition(litter.isDueToday(at: tuesday.addingTimeInterval(12 * 3600)))
precondition(!litter.isOverdue(at: tuesday.addingTimeInterval(12 * 3600)))
precondition(!litter.isDueToday(at: calendar.date(byAdding: .day, value: 1, to: sunday)!))
litter.lastCompleted = tuesday
precondition(!litter.isDueToday(at: tuesday.addingTimeInterval(12 * 3600)))
let restoredLitter = try JSONDecoder().decode(Reminder.self, from: JSONEncoder().encode(litter))
precondition(restoredLitter.weekdays == [1, 3, 5])
precondition(!litter.summary.contains(sunday.formatted(date: .omitted, time: .shortened)))
var legacyWeekly = Reminder(title: "Old weekly", message: "", date: sunday, frequency: .weekly)
precondition(legacyWeekly.weekdays == [1])
var eastern = Calendar(identifier: .gregorian)
eastern.timeZone = TimeZone(identifier: "America/New_York")!
let beforeDST = eastern.date(from: DateComponents(year: 2026, month: 3, day: 5))!
let afterDST = eastern.date(from: DateComponents(year: 2026, month: 3, day: 8))!
litter.date = beforeDST
litter.lastCompleted = nil
precondition(litter.nextWeeklyAfterCompletion(at: beforeDST.addingTimeInterval(12 * 3600), calendar: eastern) == afterDST)
print("Weekday checks passed: Sun/Tue/Thu advancement, dashboard days, completion suppression, all-day display, persistence, legacy weekly and daylight saving.")
'''
checks += r'''
for months in [1, 3, 6] {
    var repeatTask = Reminder(title: "Flexible repeat", message: "", date: jan, frequency: .flexible, interval: months)
    precondition(repeatTask.isAvailableFlexible(at: jan))
    precondition(!repeatTask.isDueToday(at: jan))
    repeatTask.markCompleted(at: jan)
    precondition(!repeatTask.completed)
    precondition(!repeatTask.isAvailableFlexible(at: jan))
    let firstHistory = repeatTask.history
    repeatTask.markCompleted(at: calendar.date(byAdding: .day, value: 1, to: jan)!)
    precondition(repeatTask.history == firstHistory) // Once per calendar month, even if tapped twice.
    let due = calendar.date(byAdding: .month, value: months, to: calendar.dateInterval(of: .month, for: jan)!.start)!
    precondition(repeatTask.dueMonth == due)
    precondition(repeatTask.isAvailableFlexible(at: due))
    precondition(!repeatTask.isAvailableFlexible(at: due.addingTimeInterval(-1)))
    let late = calendar.date(byAdding: .month, value: 1, to: due)!
    precondition(repeatTask.isAvailableFlexible(at: late))
    repeatTask.markCompleted(at: late)
    precondition(repeatTask.dueMonth == calendar.date(byAdding: .month, value: months, to: late)!)
}
var onceFlexible = Reminder(title: "One-off", message: "", date: .distantPast, frequency: .anytime)
precondition(onceFlexible.isAvailableFlexible(at: jan))
onceFlexible.markCompleted(at: jan)
precondition(onceFlexible.completed && !onceFlexible.isAvailableFlexible(at: jan))
var futureFlexible = Reminder(title: "Future", message: "", date: calendar.date(byAdding: .month, value: 1, to: jan)!, frequency: .flexible)
let dated = Reminder(title: "Today", message: "", date: jan, frequency: .once)
let unscheduled = Reminder(title: "Whenever", message: "", date: .distantPast, frequency: .anytime)
let pool = [dated, unscheduled, futureFlexible, onceFlexible]
let todays = pool.filter { $0.isDueToday(at: jan) }
let flexibles = pool.filter { $0.isAvailableFlexible(at: jan) }
precondition(todays.map(\.id) == [dated.id])
precondition(flexibles.map(\.id) == [unscheduled.id])
precondition(Set(todays.map(\.id)).isDisjoint(with: Set(flexibles.map(\.id))))
for _ in 0..<50 { precondition(todays.randomElement()?.id == dated.id && flexibles.randomElement()?.id == unscheduled.id) }
// Timed tasks stay visible today but enter random selection only at their due time.
let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: jan)!
let justBefore = evening.addingTimeInterval(-1)
for frequency: Reminder.Frequency in [.once, .daily, .weekly, .monthly, .custom] {
    var timed = Reminder(title: "Timed", message: "", date: evening, frequency: frequency)
    timed.allDay = false
    precondition(timed.isDueToday(at: justBefore))
    precondition(!timed.isEligibleForTodayRandom(at: justBefore))
    precondition(timed.isEligibleForTodayRandom(at: evening))
    precondition(timed.isEligibleForTodayRandom(at: evening.addingTimeInterval(1)))
    if frequency != .once {
        timed.date = calendar.date(byAdding: .day, value: -7, to: evening)!
        if frequency == .monthly { timed.date = calendar.date(byAdding: .month, value: -1, to: evening)! }
        precondition(!timed.isEligibleForTodayRandom(at: justBefore))
        precondition(timed.isEligibleForTodayRandom(at: evening))
    }
}
var deferredTimed = Reminder(title: "Deferred", message: "", date: evening, frequency: .once)
deferredTimed.deferredUntil = evening
precondition(!deferredTimed.isEligibleForTodayRandom(at: justBefore))
precondition(deferredTimed.isEligibleForTodayRandom(at: evening))
var allDayRandom = Reminder(title: "All day", message: "", date: jan, frequency: .once)
allDayRandom.allDay = true
precondition(allDayRandom.isEligibleForTodayRandom(at: justBefore))
allDayRandom.completed = true
precondition(!allDayRandom.isEligibleForTodayRandom(at: justBefore))
precondition(!unscheduled.isEligibleForTodayRandom(at: justBefore))
print("Today's random checks passed: future times excluded, exact due-time boundary, recurring anchors, deferred times, all-day eligibility and completed exclusions.")
print("Flexible/random checks passed: disjoint pools, completed/future exclusions, one-offs, 1/3/6 month cycles, late completions and once-per-month completion.")
'''
checks += r'''
var undoCalendar = Calendar(identifier: .gregorian)
undoCalendar.timeZone = TimeZone(identifier: "America/New_York")!
let completionDay = undoCalendar.date(from: DateComponents(year: 2030, month: 11, day: 3, hour: 23, minute: 59))!
let followingDay = undoCalendar.date(byAdding: .minute, value: 2, to: completionDay)!
for frequency: Reminder.Frequency in [.once, .daily, .weekly, .monthly, .flexible] {
    var candidate = Reminder(title: "Undo", message: "", date: completionDay, frequency: frequency)
    let originalDate = candidate.date
    candidate.markCompleted(at: completionDay, calendar: undoCalendar)
    precondition(candidate.wasCompletedToday(at: completionDay, calendar: undoCalendar))
    precondition(!candidate.wasCompletedToday(at: followingDay, calendar: undoCalendar))
    let saved = try JSONDecoder().decode(Reminder.self, from: JSONEncoder().encode(candidate))
    candidate = saved
    candidate.undoTodayCompletion(at: completionDay, calendar: undoCalendar)
    precondition(!candidate.completed && candidate.lastCompleted == nil && candidate.history.isEmpty)
    precondition(candidate.date == originalDate)
    precondition(!candidate.wasCompletedToday(at: completionDay, calendar: undoCalendar))
}
print("Completed-today checks passed: calendar midnight, recurring and one-off undo, original due date and saved undo state.")
'''
checks += r'''
do {
func due(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
let monday = due(2030, 11, 4)
let tuesday = due(2030, 11, 5)
var weeklyDeferred = Reminder(title: "Weekly", message: "", date: monday, frequency: .weekly)
let originalWeekly = weeklyDeferred
weeklyDeferred.moveToTomorrow(at: monday)
precondition(weeklyDeferred.date == originalWeekly.date && weeklyDeferred.frequency == originalWeekly.frequency && weeklyDeferred.selectedWeekdays == originalWeekly.selectedWeekdays && weeklyDeferred.recurrenceAnchor == nil)
precondition(!weeklyDeferred.isDueToday(at: monday) && weeklyDeferred.isDueToday(at: tuesday))
precondition(!weeklyDeferred.isOverdue(at: monday))
weeklyDeferred = try JSONDecoder().decode(Reminder.self, from: JSONEncoder().encode(weeklyDeferred))
precondition(weeklyDeferred.deferredUntil == tuesday)
weeklyDeferred.markCompleted(at: tuesday)
precondition(weeklyDeferred.date == due(2030, 11, 11) && weeklyDeferred.deferredUntil == nil)
weeklyDeferred.undoTodayCompletion(at: tuesday)
precondition(weeklyDeferred.date == monday && weeklyDeferred.deferredUntil == tuesday)
var month31 = Reminder(title: "31st", message: "", date: due(2030, 10, 31), frequency: .monthly)
month31.moveToTomorrow(at: due(2030, 10, 31))
month31.markCompleted(at: due(2030, 11, 1))
precondition(month31.date == due(2030, 12, 31))
var every3Days = Reminder(title: "Three days", message: "", date: due(2030, 1, 1), frequency: .custom, interval: 3, unit: .days)
every3Days.moveToTomorrow(at: due(2030, 1, 2))
every3Days.markCompleted(at: due(2030, 1, 3))
precondition(every3Days.date == due(2030, 1, 4))
for frequency: Reminder.Frequency in [.once, .anytime, .flexible, .daily] {
    var moved = Reminder(title: "Deferred", message: "", date: monday, frequency: frequency)
    moved.moveToTomorrow(at: monday)
    precondition(moved.deferredUntil != nil && moved.isDueToday(at: tuesday) && !moved.isDueToday(at: monday))
    precondition(!moved.isAvailableFlexible(at: monday) && !moved.isAvailableFlexible(at: tuesday))
    precondition(moved.history.isEmpty && moved.lastCompleted == nil && moved.frequency == frequency && moved.date == monday)
    let oldOverride = moved.deferredUntil
    moved.moveToTomorrow(at: monday)
    precondition(moved.deferredUntil == oldOverride)
}
var dstTask = Reminder(title: "DST", message: "", date: due(2030, 11, 2), frequency: .daily)
dstTask.moveToTomorrow(at: due(2030, 11, 2))
precondition(dstTask.deferredUntil == due(2030, 11, 3))
print("Move-to-tomorrow checks passed: weekly cadence, monthly day 31, custom anchor, one-offs, flexible tasks, time preservation, DST, persistence, repeat clicks and completion undo.")
}
'''
with tempfile.TemporaryDirectory(prefix="NotifyMe-checks-") as directory:
    script = Path(directory) / "Checks.swift"
    script.write_text("import Foundation\n" + model + method + "\n" + checks)
    subprocess.run(["swift", "-module-cache-path", directory + "/cache", str(script)], check=True)
