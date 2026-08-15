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

    func testLastChoiceIsUsedWhenNoLessonIsCurrent() {
        var selection = RecordingSubjectSelection()

        selection.refresh(catalogue: [biology, mathematics], current: nil, lastSelectedID: mathematics.id)

        XCTAssertEqual(selection.selected, mathematics)
    }

    func testCatalogueIsDeduplicatedAndSorted() {
        var selection = RecordingSubjectSelection()

        selection.refresh(catalogue: [mathematics, biology, biology], current: nil)

        XCTAssertEqual(selection.catalogue.map(\.name), ["Biologie", "Mathematik"])
    }

    private func lesson(subject: String) -> BackendAPI.Lesson {
        BackendAPI.Lesson(
            date: "2026-08-15", start: "08:00", end: "08:45",
            startMs: nil, endMs: nil, subject: subject, subjectLong: nil,
            title: subject, teacher: "", room: "", cancelled: false,
            substitution: false, info: "", type: nil
        )
    }
}
