@testable import MossLive
import XCTest

final class LearnDecodingTests: XCTestCase {
    func testOverviewDecodesTodayEstimateMasteryAndSubjects() throws {
        let data = Data(#"""
        {
          "due_total": 3,
          "card_total": 12,
          "estimated_minutes": 2,
          "mastery": 0.625,
          "subjects": [
            {"subject": "Biologie", "due": 2, "total": 7, "mastery": 0.75},
            {"subject": null, "due": 1, "total": 5, "mastery": 0.5}
          ],
          "sessions_with_cards": ["lesson-1"]
        }
        """#.utf8)

        let overview = try JSONDecoder().decode(BackendAPI.LearnOverview.self, from: data)

        XCTAssertEqual(overview.dueTotal, 3)
        XCTAssertEqual(overview.estimatedMinutes, 2)
        XCTAssertEqual(overview.mastery, 0.625, accuracy: 0.001)
        XCTAssertEqual(overview.subjects.map(\.displayName), ["Biologie", "Sonstige"])
    }

    func testCardKeepsEveryTraceableLessonSource() throws {
        let data = Data(#"""
        {
          "id": "concept-1", "session_id": "lesson-1", "subject": "Biologie",
          "lesson_title": "Photosynthese", "question": "Warum ist Chlorophyll wichtig?",
          "options": [], "answer": 0, "explanation": "Es absorbiert Licht.",
          "kind": "free_text", "expected_answer": "Chlorophyll nimmt Lichtenergie auf.",
          "concept": "Photosynthese", "difficulty": 2, "source_label": "Lichtreaktion",
          "source_start_ms": 12000, "source_end_ms": null, "source_revision": 0,
          "box": 0, "due_date": "2026-08-14", "stability": 0,
          "difficulty_score": 5, "reps": 0, "lapses": 0,
          "sources": [
            {"session_id": "lesson-1", "lesson_title": "Photosynthese",
             "source_label": "Lichtreaktion", "source_start_ms": 12000,
             "source_end_ms": null, "transcript_revision": 0},
            {"session_id": "lesson-2", "lesson_title": "Energie",
             "source_label": "Chlorophyll", "source_start_ms": 44000,
             "source_end_ms": null, "transcript_revision": 1}
          ]
        }
        """#.utf8)

        let card = try JSONDecoder().decode(BackendAPI.LearnCard.self, from: data)

        XCTAssertEqual(card.kind, .freeText)
        XCTAssertEqual(card.sources.map(\.sessionId), ["lesson-1", "lesson-2"])
        XCTAssertEqual(card.sources[1].timeSeconds, 44, accuracy: 0.001)
    }

    func testSemanticEvaluationDecodesAllFourOutcomes() throws {
        for value in ["correct", "partial", "incorrect", "misconception"] {
            let data = Data(#"{"category":"\#(value)","feedback":"Hinweis","correct_answer":"Antwort"}"#.utf8)
            let evaluation = try JSONDecoder().decode(BackendAPI.LearnEvaluation.self, from: data)
            XCTAssertEqual(evaluation.category.rawValue, value)
        }
    }
}

final class LearnReviewSessionTests: XCTestCase {
    func testProgressAdvancesOneCardAtATime() throws {
        let cards = try JSONDecoder().decode(
            [BackendAPI.LearnCard].self,
            from: Data("[\(Self.cardJSON(id: "one")),\(Self.cardJSON(id: "two"))]".utf8)
        )
        var session = LearnReviewSession(cards: cards)

        XCTAssertEqual(session.currentCard?.id, "one")
        XCTAssertEqual(session.completedCount, 0)
        XCTAssertEqual(session.progress, 0, accuracy: 0.001)
        session.advance()
        XCTAssertEqual(session.currentCard?.id, "two")
        XCTAssertEqual(session.progress, 0.5, accuracy: 0.001)
        session.advance()
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.progress, 1, accuracy: 0.001)
    }

    private static func cardJSON(id: String) -> String {
        #"""
        {"id":"\#(id)","session_id":"lesson-1","subject":"Mathe",
         "lesson_title":"Addition","question":"Was ist 2+2?","options":[],"answer":0,
         "explanation":"Vier.","kind":"free_text","expected_answer":"4","concept":"Addition",
         "difficulty":1,"source_label":"Addition","source_start_ms":1000,"source_end_ms":null,
         "source_revision":0,"box":0,"due_date":"2026-08-14","stability":0,
         "difficulty_score":5,"reps":0,"lapses":0,"sources":[]}
        """#
    }
}
