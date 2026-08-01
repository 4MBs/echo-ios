@testable import MossLive
import XCTest

final class LearnModelTests: XCTestCase {
    func testLegacyLearnCardStillDecodes() throws {
        let json = #"""
        {
          "id":"c1","session_id":"s1","subject":"Mathematik",
          "lesson_title":"Bruchrechnung","question":"Was ist 1/2 + 1/2?",
          "options":["1","2"],"answer":0,"explanation":"Zwei Hälften ergeben ein Ganzes.",
          "box":2,"due_date":"2026-08-01"
        }
        """#

        let card = try JSONDecoder().decode(BackendAPI.LearnCard.self, from: Data(json.utf8))

        XCTAssertEqual(card.id, "c1")
        XCTAssertEqual(card.kind, nil)
        XCTAssertEqual(card.reps, nil)
        XCTAssertEqual(card.box, 2)
    }

    func testRichLearnCardDecodesSourceAndAdaptiveFields() throws {
        let json = #"""
        {
          "id":"c2","session_id":"s2","subject":"Biologie",
          "lesson_title":"Fotosynthese","question":"Erkläre die Fotosynthese.",
          "options":[],"answer":0,"explanation":"Pflanzen wandeln Lichtenergie um.",
          "kind":"free_text","expected_answer":"Lichtenergie wird in chemische Energie umgewandelt.",
          "concept":"Fotosynthese","difficulty":3,"source_label":"Unterricht · 12:30",
          "source_start_ms":750000,"source_end_ms":780000,"source_revision":4,
          "stability":6.5,"difficulty_score":5.2,"reps":4,"lapses":1,
          "box":3,"due_date":"2026-08-03"
        }
        """#

        let card = try JSONDecoder().decode(BackendAPI.LearnCard.self, from: Data(json.utf8))

        XCTAssertEqual(card.kind, "free_text")
        XCTAssertEqual(card.concept, "Fotosynthese")
        XCTAssertEqual(card.sourceStartMs, 750_000)
        XCTAssertEqual(card.sourceRevision, 4)
        XCTAssertEqual(card.stability, 6.5)
        XCTAssertEqual(card.reps, 4)
    }

    func testExamAndDailyPlanDecode() throws {
        let examJSON = #"""
        {
          "id":"e1","name":"Klassenarbeit","subject":"Geschichte",
          "exam_date":"2026-08-14","scope_start":"2026-06-01","scope_end":"2026-08-13",
          "daily_minutes":30,"target":"Note 2","session_ids":["s1","s2"],
          "card_count":24,"readiness":0.72,"days_remaining":13
        }
        """#
        let planJSON = #"""
        {
          "date":"2026-08-01","requested_minutes":30,"estimated_minutes":12,
          "cards":[],
          "blocks":[{"subject":"Geschichte","exam_name":"Klassenarbeit","card_count":8,
                     "estimated_minutes":6,"reason":"Prüfung in 13 Tagen"}]
        }
        """#

        let exam = try JSONDecoder().decode(BackendAPI.LearnExam.self, from: Data(examJSON.utf8))
        let plan = try JSONDecoder().decode(BackendAPI.LearnDailyPlan.self, from: Data(planJSON.utf8))

        XCTAssertEqual(exam.sessionIds, ["s1", "s2"])
        XCTAssertEqual(exam.readiness, 0.72)
        XCTAssertEqual(plan.requestedMinutes, 30)
        XCTAssertEqual(plan.blocks.first?.examName, "Klassenarbeit")
    }
}
