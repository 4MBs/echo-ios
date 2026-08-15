@testable import MossLive
import XCTest

final class RecordingLessonMatchTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_755_000_000)

    func testTheRunningLessonWins() {
        let plan = [
            lesson("BIO", from: -60, to: -10),
            lesson("MAT", from: -5, to: 40),
            lesson("PHY", from: 45, to: 90),
        ]

        XCTAssertEqual(RecordingLessonMatch.lesson(in: plan, at: noon)?.subject, "MAT")
    }

    func testARecordingStartedShortlyBeforeTheBellBelongsToThatLesson() {
        let plan = [lesson("MAT", from: 6, to: 51)]

        XCTAssertEqual(RecordingLessonMatch.lesson(in: plan, at: noon)?.subject, "MAT")
    }

    func testARecordingStartedJustAfterTheLessonEndedStillBelongsToIt() {
        let plan = [lesson("MAT", from: -50, to: -6)]

        XCTAssertEqual(RecordingLessonMatch.lesson(in: plan, at: noon)?.subject, "MAT")
    }

    func testTheNearestLessonWinsWhenTwoAreWithinReach() {
        let plan = [
            lesson("BIO", from: -55, to: -9),
            lesson("MAT", from: 3, to: 48),
        ]

        XCTAssertEqual(RecordingLessonMatch.lesson(in: plan, at: noon)?.subject, "MAT")
    }

    func testALessonTooFarAwayNamesNothing() {
        let plan = [lesson("MAT", from: 45, to: 90)]

        XCTAssertNil(RecordingLessonMatch.lesson(in: plan, at: noon))
    }

    func testACancelledLessonIsNeverTheAnswer() {
        let plan = [lesson("MAT", from: -5, to: 40, cancelled: true)]

        XCTAssertNil(RecordingLessonMatch.lesson(in: plan, at: noon))
    }

    func testALessonWithoutRealTimesIsIgnored() {
        let plan = [BackendAPI.Lesson(
            date: "2026-08-15", start: "08:00", end: "08:45",
            startMs: nil, endMs: nil, subject: "MAT", subjectLong: "Mathematik",
            title: "Mathematik", teacher: "", room: "", cancelled: false,
            substitution: false, info: "", type: nil
        )]

        XCTAssertNil(RecordingLessonMatch.lesson(in: plan, at: noon))
    }

    private func lesson(
        _ subject: String,
        from startMinutes: Int,
        to endMinutes: Int,
        cancelled: Bool = false
    ) -> BackendAPI.Lesson {
        BackendAPI.Lesson(
            date: "2026-08-15",
            start: "08:00",
            end: "08:45",
            startMs: milliseconds(noon.addingTimeInterval(Double(startMinutes) * 60)),
            endMs: milliseconds(noon.addingTimeInterval(Double(endMinutes) * 60)),
            subject: subject,
            subjectLong: subject,
            title: subject,
            teacher: "",
            room: "",
            cancelled: cancelled,
            substitution: false,
            info: "",
            type: nil
        )
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
