"""Exercise the actual delegate callbacks from a background queue."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'HouseHippo/HouseHippoApp.swift').read_text()
model = source[source.index('struct Reminder:'):source.index('final class NotificationDelegate')]
model += '\n' + (root / 'HouseHippo/Recurrence.swift').read_text()
delegate = source[source.index('final class NotificationDelegate'):source.index('@MainActor final class ReminderStore')]
# Minimal notification inputs let the macOS test exercise callbacks without
# scheduling real alerts or requiring notification permissions.
stubs = r'''
protocol UNUserNotificationCenterDelegate {}
struct UNUserNotificationCenter {}
struct UNNotificationPresentationOptions: OptionSet {
    let rawValue: Int
    static let banner = Self(rawValue: 1)
    static let list = Self(rawValue: 2)
    static let sound = Self(rawValue: 4)
}
let UNNotificationDefaultActionIdentifier = "default"
struct Content { var userInfo: [String: Any] }
struct Request { var content: Content }
struct UNNotification { var request: Request }
struct UNNotificationResponse { var actionIdentifier: String; var notification: UNNotification }
'''
checks = r'''
let delegate = NotificationDelegate.shared
let center = UNUserNotificationCenter()
var finished = Set<Int>()
let inputs: [(String, [String: Any])] = [
    ("default", ["shortcutName": "Open Fertility Friend"]),
    ("dismiss", ["shortcutName": "Open Fertility Friend"]),
    ("default", [:]),
    ("default", ["shortcutName": "  "]),
    ("default", ["shortcutName": 42])
]
DispatchQueue.global().async {
    for (index, input) in inputs.enumerated() {
        let notification = UNNotification(request: Request(content: Content(userInfo: input.1)))
        let response = UNNotificationResponse(actionIdentifier: input.0, notification: notification)
        delegate.userNotificationCenter(center, didReceive: response) {
            precondition(Thread.isMainThread)
            precondition(finished.insert(index).inserted, "Completion called twice")
        }
    }
    let notification = UNNotification(request: Request(content: Content(userInfo: [:])))
    delegate.userNotificationCenter(center, willPresent: notification) { options in
        precondition(Thread.isMainThread)
        precondition(options.isEmpty) // macOS deliberately keeps alerts silent.
        precondition(finished.insert(5).inserted)
    }
}
let deadline = Date().addingTimeInterval(5)
while finished.count < 6 && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(finished.count == 6, "Missing notification completion")
print("Notification callbacks passed: background delivery, main-thread completion exactly once, normal taps, dismissals, missing/blank/invalid names and foreground presentation.")
'''
with tempfile.TemporaryDirectory(prefix='HouseHippo-notifications-') as directory:
    script = Path(directory) / 'Checks.swift'
    script.write_text('import Foundation\nimport Combine\n' + stubs + model + delegate + checks)
    subprocess.run(['swift', '-module-cache-path', directory + '/cache', str(script)], check=True)
