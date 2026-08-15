import Foundation

/// Subject state for one pending or active recording. A manual choice remains
/// authoritative until the recording has ended and a fresh selection begins.
struct RecordingSubjectSelection: Sendable {
    private(set) var catalogue: [BackendAPI.SubjectInfo] = []
    private(set) var selected: BackendAPI.SubjectInfo?
    private(set) var confirmed: BackendAPI.SubjectInfo?
    private(set) var isManual = false

    mutating func refresh(
        catalogue values: [BackendAPI.SubjectInfo],
        current: BackendAPI.Lesson?,
        lastSelectedID: String? = nil
    ) {
        var unique: [String: BackendAPI.SubjectInfo] = [:]
        for subject in values {
            unique[subject.id] = subject
        }
        catalogue = unique.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if isManual, let selected, catalogue.contains(selected) { return }
        let currentSubject = current.flatMap { lesson in
            catalogue.first {
                $0.short.caseInsensitiveCompare(lesson.subject) == .orderedSame
                    || $0.name.caseInsensitiveCompare(lesson.subjectLong ?? lesson.subject) == .orderedSame
            }
        }
        selected = currentSubject ?? catalogue.first { $0.id == lastSelectedID }
        confirmed = nil
        isManual = false
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
