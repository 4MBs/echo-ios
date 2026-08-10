import Foundation
import UserNotifications

/// Daily "time to study" local notification (repeats every day at the
/// configured time; the system keeps it across launches).
///
/// The only push this app sends about learning. No streak, no score, no second
/// reminder for having missed the first — the plan is a plan, not a game.
enum LearnReminder {
    static func sync(enabled: Bool, minuteOfDay: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["learn-reminder"])
        guard enabled else { return }
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zeit zum Lernen"
        content.body = "Deine Lernrunde für heute wartet."
        content.sound = .default
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let request = UNNotificationRequest(
            identifier: "learn-reminder",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        try? await center.add(request)
    }
}
