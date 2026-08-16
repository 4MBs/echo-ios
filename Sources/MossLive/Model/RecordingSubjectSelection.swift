import Foundation

/// Subject state for one pending or active recording. A manual choice remains
/// authoritative until the recording has ended and a fresh selection begins.
///
/// Automatically, the subject comes from the timetable and from nowhere else.
/// It used to fall back to the subject that was picked last, which reads as a
/// convenience and behaves as a trap: a recording made outside any lesson — an
/// evening, a free period, the holidays — was then filed under whatever was
/// recorded weeks ago, and because a subject the app sends is a manual override
/// on the server, that stale name also stopped the timetable from ever naming
/// the recording itself. Every recording ended up in one folder. Without a
/// lesson there is now simply no subject, which is what "Sonstige" is for.
struct RecordingSubjectSelection: Sendable {
    private(set) var catalogue: [BackendAPI.SubjectInfo] = []
    private(set) var selected: BackendAPI.SubjectInfo?
    private(set) var confirmed: BackendAPI.SubjectInfo?
    private(set) var isManual = false

    mutating func refresh(catalogue values: [BackendAPI.SubjectInfo], current: BackendAPI.Lesson?) {
        var unique: [String: BackendAPI.SubjectInfo] = [:]
        for subject in values {
            unique[subject.id] = subject
        }
        catalogue = unique.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if isManual, let selected, catalogue.contains(selected) { return }
        selected = current.flatMap { Self.subject(for: $0, in: catalogue) }
        confirmed = nil
        isManual = false
    }

    /// The catalogue entry a timetable lesson names.
    ///
    /// WebUntis gives a lesson a short code and (usually) a long name, and the
    /// catalogue the folders are built from carries both as well — but which of
    /// the two a school fills in is not consistent, so both are compared
    /// against both. Comparison ignores case, accents and stray spacing: a
    /// subject spelled "Gegrafie" in one table and "Geografie" in the other is
    /// the same lesson to everyone except a string comparison.
    static func subject(
        for lesson: BackendAPI.Lesson,
        in catalogue: [BackendAPI.SubjectInfo]
    ) -> BackendAPI.SubjectInfo? {
        let names = [lesson.subject, lesson.subjectLong ?? ""].map(normalized).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return catalogue.first { subject in
            let candidates = [subject.short, subject.long ?? "", subject.name].map(normalized)
            return candidates.contains { !$0.isEmpty && names.contains($0) }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    mutating func choose(_ subject: BackendAPI.SubjectInfo) {
        guard catalogue.contains(subject) else { return }
        selected = subject
        isManual = true
    }

    mutating func confirm(_ subject: BackendAPI.SubjectInfo) {
        confirmed = subject
        selected = subject
    }

    mutating func resetManualOverride() {
        isManual = false
        confirmed = nil
    }
}
