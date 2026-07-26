import Foundation
import SwiftUI

/// The lesson archive: loaded once, sorted once, grouped once.
///
/// The screens used to do this work inside `body` — a `Dictionary(grouping:)`
/// and a sort on every redraw, which meant on every keystroke in the search
/// field and on every tick of the audio player. Grouping happens here, when
/// the lessons themselves change, and nowhere else.
@MainActor
@Observable
final class LessonArchive {
    private(set) var lessons: [BackendAPI.LessonInfo] = []
    private(set) var subjects: [SubjectGroup] = []
    private(set) var recent: [BackendAPI.LessonInfo] = []
    private(set) var loading = true
    private(set) var loadError: Error?

    /// How many lessons the "Zuletzt" shelf carries.
    private static let recentCount = 3

    var isEmpty: Bool { lessons.isEmpty }

    func load(api: BackendAPI) async {
        let key = OfflineCache.Key.lessons
        if lessons.isEmpty, let cached = OfflineCache.load([BackendAPI.LessonInfo].self, key: key) {
            apply(cached)
        }
        loading = lessons.isEmpty
        loadError = nil
        do {
            let fresh = try await api.listLessons().filter { $0.segmentCount > 0 }
            apply(fresh)
            OfflineCache.save(fresh, as: key)
        } catch {
            // The archive is a list of what was recorded on this iPad. Keeping
            // it readable without the server is the whole point of storing it.
            if lessons.isEmpty { loadError = error }
        }
        loading = false
    }

    /// Deletes the server's copy, then the local one. Returns a message when
    /// the server refused, so the caller can put it in front of the user.
    ///
    /// The removal is animated here rather than at each call site: the shelf,
    /// the grid and the month sections all show the same lessons, and they
    /// should all collapse in one movement.
    func delete(_ lesson: BackendAPI.LessonInfo, api: BackendAPI) async -> String? {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            withAnimation(.snappy) {
                apply(lessons.filter { $0.id != lesson.id })
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Deletes a whole subject, the counterpart to deleting one lesson.
    /// Whatever the server did take is applied even if it then refuses one, so
    /// the screen never claims something is still there when it is gone.
    func deleteSubject(id: String, api: BackendAPI) async -> String? {
        var removed: Set<String> = []
        var failure: String?
        for lesson in group(id: id)?.lessons ?? [] {
            do {
                try await api.deleteLesson(id: lesson.id)
                BackendAPI.purgeCachedAudio(id: lesson.id)
                removed.insert(lesson.id)
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        if !removed.isEmpty {
            withAnimation(.snappy) {
                apply(lessons.filter { !removed.contains($0.id) })
            }
        }
        return failure
    }

    func group(id: String) -> SubjectGroup? {
        subjects.first { $0.id == id }
    }

    func matching(_ query: String) -> [BackendAPI.LessonInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return lessons.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.subject ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.teacher ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The only place the archive is ordered and cut into subjects. Everything
    /// downstream reads the result.
    private func apply(_ fresh: [BackendAPI.LessonInfo]) {
        lessons = fresh.sorted { $0.startedAt > $1.startedAt }
        recent = Array(lessons.prefix(Self.recentCount))
        // grouping preserves the order within each subject, so every group is
        // already newest-first
        subjects = Dictionary(grouping: lessons) { $0.subject ?? "" }
            .map { SubjectGroup(id: $0.key, lessons: $0.value) }
            .sorted { ($0.lastRecorded ?? .distantPast) > ($1.lastRecorded ?? .distantPast) }
    }
}

/// One subject and everything recorded in it, newest first. Subjects are
/// ordered by when they last ran, so the day's lessons are at the top of the
/// library rather than wherever the alphabet puts them.
struct SubjectGroup: Identifiable {
    let id: String
    let lessons: [BackendAPI.LessonInfo]

    var title: String { id.isEmpty ? "Ohne Fach" : id }
    var lastRecorded: Date? { lessons.first?.startedAt }
    var countLabel: String { lessons.count == 1 ? "1 Stunde" : "\(lessons.count) Stunden" }
}
