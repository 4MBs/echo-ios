@testable import MossLive
import XCTest

final class RecordingSubjectSelectionTests: XCTestCase {
    private let biology = BackendAPI.SubjectInfo(
        short: "BIO", long: "Biologie", name: "Biologie", teachers: ["Frau Curie"]
    )
    private let mathematics = BackendAPI.SubjectInfo(
        short: "M", long: "Mathematik", name: "Mathematik", teachers: ["Herr Gauß"]
    )

    func testCurrentUntisLessonIsSelectedInitially() {
        var selection = RecordingSubjectSelection()

        selection.refresh(catalogue: [mathematics, biology], current: lesson(subject: "BIO"))

        XCTAssertEqual(selection.selected, biology)
        XCTAssertFalse(selection.isManual)
    }

    func testManualChoiceWinsOverLaterUntisRefresh() {
        var selection = RecordingSubjectSelection()
        selection.refresh(catalogue: [biology, mathematics], current: lesson(subject: "BIO"))

        selection.choose(mathematics)
        selection.refresh(catalogue: [biology, mathematics], current: lesson(subject: "BIO"))

        XCTAssertEqual(selection.selected, mathematics)
        XCTAssertTrue(selection.isManual)
    }

    /// The bug this replaced a feature to fix: a recording made when no lesson
    /// is running — an evening, a free period, a test — used to inherit the
    /// subject that was picked last, and because the app sends its subject to
    /// the server as a manual override, that also stopped the timetable from
    /// ever naming the recording itself. Every recording landed in one folder.
    func testNoLessonMeansNoSubject() {
        var selection = RecordingSubjectSelection()
        selection.refresh(catalogue: [biology, mathematics], current: lesson(subject: "BIO"))
        selection.choose(mathematics)
        selection.resetManualOverride()

        selection.refresh(catalogue: [biology, mathematics], current: nil)

        XCTAssertNil(selection.selected)
        XCTAssertFalse(selection.isManual)
    }

    /// WebUntis is not consistent about which of the two names it fills in, and
    /// the catalogue the folders come from is a second table with the same
    /// problem. Both are compared against both.
    func testTheLessonIsMatchedOnEitherOfItsNames() {
        let catalogue = [biology, mathematics]

        XCTAssertEqual(
            RecordingSubjectSelection.subject(for: lesson(subject: "Biologie"), in: catalogue),
            biology
        )
        XCTAssertEqual(
            RecordingSubjectSelection.subject(
                for: lesson(subject: "B", long: "Mathematik"),
                in: catalogue
            ),
            mathematics
        )
    }

    /// Spelling that differs by an accent or a stray space is the same subject
    /// to everyone except a string comparison — and a lesson that fails to
    /// match silently loses its subject.
    func testMatchingIgnoresCaseAccentsAndSpacing() {
        let geography = BackendAPI.SubjectInfo(
            short: "GEO", long: "Geografie", name: "Geografie", teachers: []
        )

        XCTAssertEqual(
            RecordingSubjectSelection.subject(for: lesson(subject: " geo "), in: [geography]),
            geography
        )
        XCTAssertEqual(
            RecordingSubjectSelection.subject(
                for: lesson(subject: "GEO", long: "Geographie"),
                in: [geography]
            ),
            geography,
            "the short code still matches even when the long names differ"
        )
    }

    func testASubjectNobodyTeachesMatchesNothing() {
        XCTAssertNil(
            RecordingSubjectSelection.subject(for: lesson(subject: "AST"), in: [biology, mathematics])
        )
        XCTAssertNil(RecordingSubjectSelection.subject(for: lesson(subject: ""), in: [biology]))
    }

    func testCatalogueIsDeduplicatedAndSorted() {
        var selection = RecordingSubjectSelection()

        selection.refresh(catalogue: [mathematics, biology, biology], current: nil)

        XCTAssertEqual(selection.catalogue.map(\.name), ["Biologie", "Mathematik"])
    }

    private func lesson(subject: String, long: String? = nil) -> BackendAPI.Lesson {
        BackendAPI.Lesson(
            date: "2026-08-15", start: "08:00", end: "08:45",
            startMs: nil, endMs: nil, subject: subject, subjectLong: long,
            title: subject, teacher: "", room: "", cancelled: false,
            substitution: false, info: "", type: nil
        )
    }
}
