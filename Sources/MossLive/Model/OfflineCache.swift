import Foundation
import os

/// The last answer the server gave, kept on disk so a screen has something to
/// show before — or entirely without — a reply.
///
/// Nothing in here is expensive to keep. The lessons were recorded on this
/// iPad in the first place and their transcripts are text; the cards were
/// generated once and never change afterwards; the timetable is a few dozen
/// short strings. The only reason any of it needed the network was that it was
/// never written down.
///
/// Application Support rather than Caches: iOS empties Caches whenever it wants
/// the space back, which for offline content means it disappears exactly when
/// it is least replaceable.
enum OfflineCache {
    private static let log = Logger(subsystem: "com.fourmbs.mosslive", category: "cache")

    // MARK: - Keys

    enum Key {
        static let books = "books"
        static let lessons = "lessons"
        static let learnOverview = "learn-overview"
        static let learnCards = "learn-cards"
        static let timetableNow = "timetable-now"
        static let timetableDay = "timetable-day"

        static func lesson(_ id: String) -> String { "lesson-\(id)" }
        static func cover(_ id: String) -> String { "cover-\(id)" }
    }

    // MARK: - Storage

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Transcripts and cards are the user's own schoolwork; they should
            // not travel to iCloud backups without being asked.
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return dir
    }

    private static func file(_ key: String, _ ext: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension(ext)
    }

    // MARK: - Codable values

    static func save(_ value: some Encodable, as key: String) {
        do {
            try JSONEncoder().encode(value).write(to: file(key, "json"), options: .atomic)
        } catch {
            log.error("could not cache \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: file(key, "json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// When the cached copy was written — what a screen shows instead of
    /// pretending stale content is live.
    static func savedAt(key: String) -> Date? {
        try? file(key, "json").resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    // MARK: - Raw data (book covers)

    static func saveData(_ data: Data, as key: String) {
        try? data.write(to: file(key, "bin"), options: .atomic)
    }

    static func loadData(key: String) -> Data? {
        try? Data(contentsOf: file(key, "bin"))
    }

    // MARK: - Housekeeping

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: file(key, "json"))
        try? FileManager.default.removeItem(at: file(key, "bin"))
    }
}

/// How long ago the cached copy was written, in the words a German sentence
/// wants: "vor 5 Minuten", "gestern".
enum CacheAge {
    static func phrase(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
