import Foundation
import SwiftUI

/// Everything the Stunden tab shows: the recordings that exist, the timetable
/// weeks they belong to, and where each block sits in the grid.
///
/// All of the arranging happens here, when the data changes. A grid recomputed
/// inside `body` is a grid recomputed on every scroll frame and every tick of
/// the audio clock, which is what made the screens before this one stutter.
@MainActor
@Observable
final class StundenStore {
    private(set) var recordings: [BackendAPI.LessonInfo] = []
    private(set) var recordingsError: Error?
    private(set) var layouts: [String: WeekLayout] = [:]
    private(set) var loadingWeeks: Set<String> = []

    /// The raw weeks, kept so the layouts can be rebuilt when the recordings
    /// change without asking the server again.
    @ObservationIgnored private var fetched: [String: BackendAPI.TimetableWeek] = [:]
    @ObservationIgnored private let calendar = Calendar.current

    var hasRecordings: Bool { !recordings.isEmpty }

    func layout(for monday: Date) -> WeekLayout? {
        layouts[SchoolClock.key(monday, calendar: calendar)]
    }

    func isLoading(_ monday: Date) -> Bool {
        loadingWeeks.contains(SchoolClock.key(monday, calendar: calendar))
    }

    // MARK: Recordings

    func loadRecordings(api: BackendAPI) async {
        let key = OfflineCache.Key.lessons
        if recordings.isEmpty, let cached = OfflineCache.load([BackendAPI.LessonInfo].self, key: key) {
            recordings = cached.sorted { $0.startedAt > $1.startedAt }
            rebuildLayouts()
        }
        do {
            let fresh = try await api.listLessons().filter { $0.segmentCount > 0 }
            recordings = fresh.sorted { $0.startedAt > $1.startedAt }
            OfflineCache.save(fresh, as: key)
            recordingsError = nil
            rebuildLayouts()
        } catch {
            // The archive was recorded on this iPad; keeping it readable
            // without the server is the whole point of storing it.
            if recordings.isEmpty { recordingsError = error }
        }
    }

    func matching(_ query: String) -> [BackendAPI.LessonInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return recordings.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.subject ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.teacher ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Deletes the server's copy, then the local one. Returns a message when
    /// the server refused, so the caller can put it in front of the user.
    func delete(_ lesson: BackendAPI.LessonInfo, api: BackendAPI) async -> String? {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            withAnimation(.snappy) {
                recordings.removeAll { $0.id == lesson.id }
                rebuildLayouts()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Weeks

    func loadWeek(_ monday: Date, api: BackendAPI) async {
        let key = SchoolClock.key(monday, calendar: calendar)
        guard !loadingWeeks.contains(key) else { return }

        if layouts[key] == nil,
           let cached = OfflineCache.load(BackendAPI.TimetableWeek.self, key: OfflineCache.Key.timetableWeek(key)) {
            fetched[key] = cached
            layouts[key] = build(cached, monday: monday)
        }

        loadingWeeks.insert(key)
        defer { loadingWeeks.remove(key) }

        let dayKeys = Self.weekdays(from: monday, calendar: calendar).map(\.key)
        do {
            let week = try await api.timetableWeek(mondayKey: key, dayKeys: dayKeys)
            fetched[key] = week
            OfflineCache.save(week, as: OfflineCache.Key.timetableWeek(key))
            layouts[key] = build(week, monday: monday)
        } catch {
            // No timetable is not an empty week: the recordings made in it are
            // still the point of the screen, so they are laid out on their own.
            if layouts[key] == nil {
                layouts[key] = build(BackendAPI.TimetableWeek(days: [], holidays: []), monday: monday)
            }
        }
    }

    private func rebuildLayouts() {
        for (key, week) in fetched {
            guard let monday = SchoolClock.date(fromKey: key, calendar: calendar) else { continue }
            layouts[key] = build(week, monday: monday)
        }
    }

    private func build(_ week: BackendAPI.TimetableWeek, monday: Date) -> WeekLayout {
        WeekLayout.build(week: week, monday: monday, recordings: recordings, calendar: calendar)
    }

    /// Monday to Friday. A school week has five days; a recording made on a
    /// Saturday still turns up in search.
    static func weekdays(from monday: Date, calendar: Calendar) -> [(date: Date, key: String)] {
        (0 ..< 5).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            return (date, SchoolClock.key(date, calendar: calendar))
        }
    }
}

// MARK: - What the grid draws

/// One block in the grid. Timetable lessons and recordings that match no
/// lesson both end up here, so the grid has one kind of thing to draw and a
/// recording can never be invisible for want of a slot to sit in.
struct LessonBlock: Identifiable {
    let id: String
    let title: String
    let subject: String?
    let room: String?
    let teacher: String?
    let cancelled: Bool
    let substitution: Bool
    /// Minutes since midnight.
    let start: Int
    let end: Int
    /// Which of the overlapping columns this block sits in, and how many there
    /// are — two lessons at the same hour share the day's width.
    var column = 0
    var columns = 1
    var recording: BackendAPI.LessonInfo?
    /// False for a recording with no lesson behind it.
    var isScheduled = true
}

struct DayLayout: Identifiable {
    let date: Date
    let key: String
    let blocks: [LessonBlock]
    /// Excursions and the like: anything long enough that placing it on the
    /// time axis would push the day's real lessons aside.
    let allDay: [String]
    let holiday: String?

    var id: String { key }
    var isEmpty: Bool { blocks.isEmpty && allDay.isEmpty }
}

struct WeekLayout {
    let mondayKey: String
    let days: [DayLayout]
    let startMinute: Int
    let endMinute: Int
    /// Set when every day of the week is the same holiday — then the grid is
    /// not worth drawing at all.
    let wholeWeekHoliday: String?

    var isEmpty: Bool { days.allSatisfy(\.isEmpty) }
    var hasAllDay: Bool { days.contains { !$0.allDay.isEmpty } }

    /// Long enough that it is not a lesson but a day out.
    private static let allDayMinutes = 240
    private static let defaultRange = (start: 8 * 60, end: 16 * 60)

    static func build(
        week: BackendAPI.TimetableWeek,
        monday: Date,
        recordings: [BackendAPI.LessonInfo],
        calendar: Calendar
    ) -> WeekLayout {
        var byDay: [String: [BackendAPI.LessonInfo]] = [:]
        for recording in recordings {
            byDay[SchoolClock.key(recording.startedAt, calendar: calendar), default: []].append(recording)
        }

        var days: [DayLayout] = []
        var earliest = Int.max
        var latest = Int.min

        for day in StundenStore.weekdays(from: monday, calendar: calendar) {
            let scheduled = week.days.first { $0.date == day.key }?.lessons ?? []
            let dayRecordings = (byDay[day.key] ?? []).sorted { $0.startedAt < $1.startedAt }
            var blocks: [LessonBlock] = []
            var allDay: [String] = []
            var claimed: Set<String> = []

            for lesson in scheduled {
                guard let start = SchoolClock.minutes(lesson.start),
                      let end = SchoolClock.minutes(lesson.end), end > start
                else { continue }
                if end - start >= allDayMinutes {
                    allDay.append(lesson.title.isEmpty ? lesson.subject : lesson.title)
                    continue
                }
                // The server already cuts a recording per period, so the one
                // whose middle falls inside the slot is the slot's recording.
                let match = dayRecordings.first { recording in
                    guard !claimed.contains(recording.id) else { return false }
                    let middle = SchoolClock.minutes(
                        of: recording.startedAt.addingTimeInterval(recording.durationSeconds / 2),
                        calendar: calendar
                    )
                    return middle >= start && middle < end
                }
                if let match { claimed.insert(match.id) }
                blocks.append(
                    LessonBlock(
                        id: "\(day.key)-\(lesson.start)-\(lesson.end)-\(lesson.subject)-\(lesson.room)",
                        title: Self.name(of: lesson),
                        subject: lesson.subject.isEmpty ? nil : lesson.subject,
                        room: lesson.room.isEmpty ? nil : lesson.room,
                        teacher: lesson.teacher.isEmpty ? nil : lesson.teacher,
                        cancelled: lesson.cancelled,
                        substitution: lesson.substitution,
                        start: start,
                        end: end,
                        recording: match
                    )
                )
            }

            for recording in dayRecordings where !claimed.contains(recording.id) {
                let start = SchoolClock.minutes(of: recording.startedAt, calendar: calendar)
                let end = SchoolClock.minutes(
                    of: recording.startedAt.addingTimeInterval(recording.durationSeconds),
                    calendar: calendar
                )
                blocks.append(
                    LessonBlock(
                        id: "recording-\(recording.id)",
                        title: recording.subject ?? recording.title ?? "Aufnahme",
                        subject: recording.subject,
                        room: recording.room,
                        teacher: recording.teacher,
                        cancelled: false,
                        substitution: false,
                        start: start,
                        // a very short recording still needs to be tappable
                        end: max(end, start + 15),
                        recording: recording,
                        isScheduled: false
                    )
                )
            }

            let placed = place(blocks)
            for block in placed {
                earliest = min(earliest, block.start)
                latest = max(latest, block.end)
            }
            days.append(
                DayLayout(
                    date: day.date,
                    key: day.key,
                    blocks: placed,
                    allDay: allDay,
                    holiday: week.holidays.first { $0.covers(day.key) }?.name
                )
            )
        }

        // The grid stops where the week does: an empty afternoon should not
        // take up a third of the screen.
        var start = earliest == Int.max ? defaultRange.start : (earliest / 60) * 60
        var end = latest == Int.min ? defaultRange.end : Int((Double(latest) / 60).rounded(.up)) * 60
        if end - start < 180 { end = start + 180 }
        start = max(0, start)
        end = min(24 * 60, end)

        let holidayNames = Set(days.compactMap(\.holiday))
        let everyDayOff = holidayNames.count == 1 && days.allSatisfy { $0.holiday != nil && $0.isEmpty }

        return WeekLayout(
            mondayKey: SchoolClock.key(monday, calendar: calendar),
            days: days,
            startMinute: start,
            endMinute: end,
            wholeWeekHoliday: everyDayOff ? holidayNames.first : nil
        )
    }

    private static func name(of lesson: BackendAPI.Lesson) -> String {
        if let long = lesson.subjectLong, !long.isEmpty { return long }
        if !lesson.subject.isEmpty { return lesson.subject }
        return lesson.title.isEmpty ? "Stunde" : lesson.title
    }

    /// Overlapping blocks share the day's width. Blocks are gathered into
    /// clusters that actually touch, and within a cluster each one takes the
    /// first column that is free by the time it starts — so two parallel
    /// lessons split the day in half, and the rest of the day stays full width.
    private static func place(_ blocks: [LessonBlock]) -> [LessonBlock] {
        let sorted = blocks.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [LessonBlock] = []
        var cluster: [LessonBlock] = []
        var clusterEnd = Int.min

        func flush() {
            guard !cluster.isEmpty else { return }
            var columnEnds: [Int] = []
            var placed: [LessonBlock] = []
            for var block in cluster {
                if let free = columnEnds.firstIndex(where: { $0 <= block.start }) {
                    columnEnds[free] = block.end
                    block.column = free
                } else {
                    columnEnds.append(block.end)
                    block.column = columnEnds.count - 1
                }
                placed.append(block)
            }
            let width = max(1, columnEnds.count)
            result.append(contentsOf: placed.map {
                var block = $0
                block.columns = width
                return block
            })
            cluster = []
            clusterEnd = Int.min
        }

        for block in sorted {
            if block.start >= clusterEnd { flush() }
            cluster.append(block)
            clusterEnd = max(clusterEnd, block.end)
        }
        flush()
        return result
    }
}
