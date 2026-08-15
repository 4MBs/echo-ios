import Foundation

/// Which timetable lesson a recording started at a given moment belongs to.
///
/// A recording rarely starts on the minute the timetable says: the iPad comes
/// out while the class is still settling, or the teacher is already talking
/// when it does. So the running lesson wins, and outside one, the nearest
/// lesson within a short grace period around its slot still counts — which is
/// what makes the subject correct without anybody choosing it.
enum RecordingLessonMatch {
    /// How far outside its own slot a lesson may still claim a recording.
    static let defaultTolerance: TimeInterval = 10 * 60

    static func lesson(
        in lessons: [BackendAPI.Lesson],
        at moment: Date,
        tolerance: TimeInterval = defaultTolerance
    ) -> BackendAPI.Lesson? {
        let scheduled = lessons.compactMap { lesson -> (lesson: BackendAPI.Lesson, start: Date, end: Date)? in
            guard !lesson.cancelled, let start = lesson.startDate, let end = lesson.endDate, start <= end
            else { return nil }
            return (lesson, start, end)
        }

        if let running = scheduled.first(where: { $0.start <= moment && moment < $0.end }) {
            return running.lesson
        }

        return scheduled
            .map { ($0.lesson, distance(from: moment, start: $0.start, end: $0.end)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private static func distance(from moment: Date, start: Date, end: Date) -> TimeInterval {
        moment < start ? start.timeIntervalSince(moment) : moment.timeIntervalSince(end)
    }
}
