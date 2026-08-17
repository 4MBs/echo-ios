import Foundation
import os
import UserNotifications

/// Holds the WebUntis "current / next lesson" state (Tier 2) and schedules
/// start-of-lesson notifications (Tier 4). The backend owns the timetable.
///
/// The day's plan is kept on the iPad, because it is fixed hours before it is
/// needed and it is a few dozen short strings. Which lesson is running is then
/// only a question about the clock, and the iPad has one of those — so the
/// current-lesson banner, the auto-stop and the start-of-lesson notifications
/// all keep working through a morning without signal.
@MainActor
@Observable
final class TimetableStore {
    private(set) var enabled = false
    private(set) var current: BackendAPI.Lesson?
    private(set) var next: BackendAPI.Lesson?
    /// When the plan last came from the server.
    private(set) var savedAt: Date?

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "timetable")
    @ObservationIgnored private let settings: AppSettings

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(settings: AppSettings) {
        self.settings = settings
        // What the server last said about the login, so a launch without a
        // network doesn't look like a launch without an account.
        enabled = settings.timetableConnected
        savedAt = OfflineCache.savedAt(key: OfflineCache.Key.timetableDay)
        applyStoredDay()
    }

    private var api: BackendAPI? {
        guard settings.isConfigured, !settings.serverHost.isEmpty else { return nil }
        return BackendAPI(host: settings.serverHost, port: settings.serverPort, token: settings.authToken)
    }

    /// Fetch the current + next lesson, falling back to the stored day plan.
    /// Silent on failure (the feature is optional and the fallback is good).
    func refresh() async {
        guard let api else { return }
        do {
            let now = try await api.timetableNow()
            enabled = now.enabled
            current = now.current
            next = now.next
            settings.timetableConnected = now.enabled
            await storeTodaysPlan(api: api)
        } catch {
            log.debug("timetable/now failed: \(error.localizedDescription)")
            applyStoredDay()
        }
    }

    /// Keep today's plan on disk. Fetched once a day rather than on every poll:
    /// the plan for a day does not change while the day runs.
    private func storeTodaysPlan(api: BackendAPI) async {
        let today = Self.dayKey.string(from: Date())
        let key = OfflineCache.Key.timetableDay
        if let stored = OfflineCache.load(BackendAPI.TimetableDay.self, key: key), stored.date == today {
            return
        }
        guard let day = try? await api.timetableDay() else { return }
        OfflineCache.save(day, as: key)
        savedAt = OfflineCache.savedAt(key: key)
    }

    /// Today's plan as it is stored here, read against the clock. A plan from
    /// another day is not used at all — a stale snapshot claiming third period
    /// at six in the evening is worse than an empty banner.
    private func applyStoredDay() {
        guard let day = storedDay() else {
            current = nil
            next = nil
            return
        }
        enabled = day.enabled
        let now = Date()
        let lessons = day.lessons.filter { !$0.cancelled }
        current = lessons.first { lesson in
            guard let start = lesson.startDate, let end = lesson.endDate else { return false }
            return start <= now && now < end
        }
        next = lessons
            .filter { ($0.startDate ?? .distantPast) > now }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    /// The lesson a recording started now belongs to — the answer the app uses
    /// to label a recording without asking. The whole stored day is consulted
    /// rather than only `current`, so a recording begun in the minutes before
    /// the bell, or just after one lesson ended, still finds its subject.
    func lessonForRecording(
        at moment: Date = Date(),
        tolerance: TimeInterval = RecordingLessonMatch.defaultTolerance
    ) -> BackendAPI.Lesson? {
        let plan = storedDay()?.lessons ?? [current, next].compactMap { $0 }
        return RecordingLessonMatch.lesson(in: plan, at: moment, tolerance: tolerance)
    }

    private func storedDay() -> BackendAPI.TimetableDay? {
        guard let day = OfflineCache.load(BackendAPI.TimetableDay.self, key: OfflineCache.Key.timetableDay),
              day.date == Self.dayKey.string(from: Date())
        else { return nil }
        return day
    }

    /// Tier 4: (re)schedule a local notification at the start of each of today's
    /// remaining lessons. Clears our previous ones first. No-op when disabled.
    func syncNotifications(enabled notifyEnabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("lesson-") }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard notifyEnabled else { return }
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let recordAction = UNNotificationAction(
            identifier: "START_RECORDING_ACTION",
            title: "Aufnahme starten",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "LESSON_START",
            actions: [recordAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        // The stored plan is enough to schedule from, so a morning without
        // signal still gets its reminders.
        var day = storedDay()
        if let api, let fresh = try? await api.timetableDay() {
            OfflineCache.save(fresh, as: OfflineCache.Key.timetableDay)
            savedAt = OfflineCache.savedAt(key: OfflineCache.Key.timetableDay)
            day = fresh
        }
        guard let day else { return }

        for lesson in day.lessons {
            guard !lesson.cancelled, let start = lesson.startDate, start > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(lesson.title) beginnt"
            content.body = lesson.room.isEmpty
                ? "Zum Aufnehmen tippen"
                : "Zum Aufnehmen tippen · Raum \(lesson.room)"
            content.sound = .default
            content.categoryIdentifier = "LESSON_START"
            content.userInfo = ["action": "start-recording", "lessonId": lesson.id]
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
