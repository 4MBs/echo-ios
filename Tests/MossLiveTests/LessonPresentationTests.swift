@testable import MossLive
import XCTest

final class LessonPresentationTests: XCTestCase {
    func testAITopicIsThePrimaryTitleAndSubjectRemainsVisible() throws {
        let lesson = try makeLesson(
            topic: "Ursachen der Revolution",
            title: "Geschichte · Raum 204",
            subject: "Geschichte"
        )

        XCTAssertEqual(lesson.displayTitle, "Ursachen der Revolution")
        XCTAssertEqual(lesson.displaySubject, "Geschichte")
        XCTAssertEqual(lesson.compactDisplayTitle, "Ursachen der Revolution · Geschichte")
        XCTAssertFalse(lesson.usesDateDisplayTitle)
    }

    func testOldSummaryDerivesAContentTitle() throws {
        let lesson = try makeLesson(
            summaryExcerpt: "Ableitung von Polynomfunktionen. Danach wurde die Kettenregel geübt.",
            title: "Mathematik",
            subject: "Mathematik"
        )

        XCTAssertEqual(lesson.displayTitle, "Ableitung von Polynomfunktionen")
        XCTAssertEqual(lesson.displaySubject, "Mathematik")
    }

    func testWhitespaceTopicFallsBackToTimetableTitle() throws {
        let lesson = try makeLesson(topic: "   ", title: "Mathematik", subject: "MA")

        XCTAssertEqual(lesson.displayTitle, "Mathematik")
        XCTAssertEqual(lesson.displaySubject, "MA")
        XCTAssertEqual(lesson.compactDisplayTitle, "Mathematik · MA")
    }

    func testSubjectIsNotRepeatedWhenItIsAlsoTheFallbackTitle() throws {
        let lesson = try makeLesson(subject: "Physik")

        XCTAssertEqual(lesson.displayTitle, "Physik")
        XCTAssertEqual(lesson.displaySubject, "Physik")
        XCTAssertEqual(lesson.compactDisplayTitle, "Physik")
    }

    func testUnnamedLessonUsesItsDateAsTheFinalFallback() throws {
        let lesson = try makeLesson()

        XCTAssertTrue(lesson.usesDateDisplayTitle)
        XCTAssertNil(lesson.displaySubject)
        XCTAssertEqual(
            lesson.displayTitle,
            lesson.startedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func testSearchFindsVisibleAITitleAndSubject() throws {
        let lesson = try makeLesson(topic: "Ursache und Wirkung", subject: "Physik")

        XCTAssertTrue(lesson.matches("Wirkung"))
        XCTAssertTrue(lesson.matches("Physik"))
        XCTAssertFalse(lesson.matches("Zellatmung"))
    }

    private func makeLesson(
        topic: String? = nil,
        summaryExcerpt: String? = nil,
        title: String? = nil,
        subject: String? = nil
    ) throws -> BackendAPI.LessonInfo {
        var object: [String: Any] = [
            "id": "lesson-1",
            "started_at_ms": 1_700_000_000_000,
            "segment_count": 4,
            "speech_seconds": 120,
            "duration_seconds": 180,
            "has_summary": topic != nil || summaryExcerpt != nil,
            "has_audio": true,
        ]
        if let topic { object["topic"] = topic }
        if let summaryExcerpt { object["summary_excerpt"] = summaryExcerpt }
        if let title { object["title"] = title }
        if let subject { object["subject"] = subject }

        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(BackendAPI.LessonInfo.self, from: data)
    }
}
