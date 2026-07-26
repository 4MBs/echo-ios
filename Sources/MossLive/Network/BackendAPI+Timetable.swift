import Foundation

/// The week the Stunden grid draws.
///
/// The server the app talks to today answers one day at a time and knows
/// nothing about holidays — WebUntis has them, but only the Fedora backend
/// talks to WebUntis. So the app asks for the week it wants and, from a server
/// that has never heard of the endpoint, builds the same value out of five day
/// requests instead. The grid is finished before the server is, and holidays
/// appear the day it catches up, with no app change.
extension BackendAPI {
    struct Holiday: Codable, Sendable, Identifiable, Equatable {
        let name: String
        /// `yyyy-MM-dd`, inclusive at both ends.
        let start: String
        let end: String

        var id: String { "\(start)-\(end)-\(name)" }

        /// Day keys are `yyyy-MM-dd`, which compares correctly as text.
        func covers(_ dayKey: String) -> Bool {
            start <= dayKey && dayKey <= end
        }
    }

    struct TimetableWeek: Codable, Sendable {
        var days: [TimetableDay]
        var holidays: [Holiday]

        init(days: [TimetableDay], holidays: [Holiday]) {
            self.days = days
            self.holidays = holidays
        }

        enum CodingKeys: String, CodingKey {
            case days, holidays
        }

        /// Both fields are optional on the wire: a server that gained the
        /// endpoint before it gained holidays is still a valid answer.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            days = try container.decodeIfPresent([TimetableDay].self, forKey: .days) ?? []
            holidays = try container.decodeIfPresent([Holiday].self, forKey: .holidays) ?? []
        }
    }

    func timetableWeek(mondayKey: String, dayKeys: [String]) async throws -> TimetableWeek {
        do {
            let data = try await request(
                "/timetable/week",
                query: [URLQueryItem(name: "start", value: mondayKey)]
            )
            return try JSONDecoder().decode(TimetableWeek.self, from: data)
        } catch let error as APIError where error.status == 404 {
            return try await weekFromDays(dayKeys)
        }
    }

    /// Five requests at once, for a server without the week endpoint.
    private func weekFromDays(_ dayKeys: [String]) async throws -> TimetableWeek {
        let days = try await withThrowingTaskGroup(of: TimetableDay.self) { group in
            for key in dayKeys {
                group.addTask { try await self.timetableDay(date: key) }
            }
            var collected: [TimetableDay] = []
            for try await day in group {
                collected.append(day)
            }
            return collected
        }
        return TimetableWeek(
            days: days.sorted { ($0.date ?? "") < ($1.date ?? "") },
            holidays: []
        )
    }
}

/// Wall-clock helpers the grid needs. Times arrive as `"08:50"` and dates as
/// `"2026-07-27"`; both are split by hand rather than run through a
/// DateFormatter, which is the expensive way to read four digits.
enum SchoolClock {
    /// Minutes since midnight, for laying a lesson out on the time axis.
    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] >= 0, parts[0] < 24 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func minutes(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// `yyyy-MM-dd` — the key the timetable speaks in.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The Monday of the week `date` falls in.
    static func monday(of date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        // weekday is 1=Sunday in the Gregorian calendar, whatever the locale's
        // first day of the week is — a school week always starts on Monday.
        let weekday = calendar.component(.weekday, from: start)
        let offset = weekday == 1 ? -6 : -(weekday - 2)
        return calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }
}
