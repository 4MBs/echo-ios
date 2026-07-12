import Foundation
import os
import UserNotifications

/// Holds the WebUntis "current / next lesson" state (Tier 2) and schedules
/// start-of-lesson notifications (Tier 4). The backend owns the timetable; this
/// just fetches and displays it. Polling + auto-stop are driven by AppModel.
@MainActor
@Observable
final class TimetableStore {
    private(set) var enabled = false
    private(set) var current: BackendAPI.Lesson?
    private(set) var next: BackendAPI.Lesson?

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "timetable")
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var api: BackendAPI? {
        guard settings.isConfigured, !settings.serverHost.isEmpty else { return nil }
        return BackendAPI(host: settings.serverHost, port: settings.serverPort, token: settings.authToken)
    }

    /// Fetch the current + next lesson. Silent on failure (feature is optional).
    func refresh() async {
        guard let api else { return }
        do {
            let now = try await api.timetableNow()
            enabled = now.enabled
            current = now.current
            next = now.next
        } catch {
            log.debug("timetable/now failed: \(error.localizedDescription)")
        }
    }

    /// Tier 4: (re)schedule a local notification at the start of each of today's
    /// remaining lessons. Clears our previous ones first. No-op when disabled.
    func syncNotifications(enabled notifyEnabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("lesson-") }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard notifyEnabled, let api else { return }
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted, let day = try? await api.timetableDay() else { return }

        for lesson in day.lessons {
            guard !lesson.cancelled, let start = lesson.startDate, start > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(lesson.title) beginnt"
            content.body = lesson.room.isEmpty
                ? "Zum Aufnehmen tippen"
                : "Zum Aufnehmen tippen · Raum \(lesson.room)"
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            let request = UNNotificationRequest(
                identifier: "lesson-\(lesson.id)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }
}
