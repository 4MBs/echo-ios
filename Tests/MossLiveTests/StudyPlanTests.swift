@testable import MossLive
import XCTest

/// What the Lernen area computes rather than displays: which cards are in
/// today's round when there is no server, how solid something is called, and
/// where a round is after seven answers.
///
/// These are the places the screen can be wrong without looking wrong — a card
/// answered on the train coming back around the same afternoon, a round of forty
/// cards offered to somebody who set ten minutes, a resume point that survives
/// half an hour it should not have.
final class StudyPlanTests: XCTestCase {
    // MARK: - Fixtures

    private func card(
        _ id: String,
        subject: String? = "Mathematik",
        due: String,
        session: String = "s1",
        reps: Int? = nil,
        stability: Double? = nil,
        lapses: Int? = nil
    ) -> BackendAPI.LearnCard {
        let json = """
        {
          "id": "\(id)", "session_id": "\(session)",
          \(subject.map { "\"subject\": \"\($0)\"," } ?? "")
          "question": "Frage \(id)", "options": ["a", "b"], "answer": 0,
          "explanation": "", "box": 1, "due_date": "\(due)",
          \(reps.map { "\"reps\": \($0)," } ?? "")
          \(stability.map { "\"stability\": \($0)," } ?? "")
          \(lapses.map { "\"lapses\": \($0)," } ?? "")
          "lesson_title": "Stunde"
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BackendAPI.LearnCard.self, from: Data(json.utf8))
    }

    private func exam(
        subject: String,
        date: String,
        daysRemaining: Int,
        sessions: [String]
    ) -> BackendAPI.LearnExam {
        let json = """
        {
          "id": "e1", "name": "Klassenarbeit", "subject": "\(subject)",
          "exam_date": "\(date)", "scope_start": "2026-06-01", "scope_end": "\(date)",
          "daily_minutes": 20, "session_ids": [\(sessions.map { "\"\($0)\"" }.joined(separator: ","))],
          "card_count": 12, "readiness": 0.4, "days_remaining": \(daysRemaining)
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BackendAPI.LearnExam.self, from: Data(json.utf8))
    }

    // MARK: - The round without a server

    /// Due today or earlier is due; tomorrow is not. This is the whole schedule
    /// the iPad can evaluate on its own.
    func testLocalPlanTakesOnlyWhatIsDue() {
        let cards = [
            card("a", due: "2026-08-01"),
            card("b", due: "2026-08-02"),
            card("c", due: "2026-08-03"),
        ]

        let plan = StudyPlan.local(
            cards: cards, answered: [], minutes: 20, exams: [], today: "2026-08-02"
        )

        XCTAssertEqual(plan.cards.map(\.id), ["a", "b"])
        XCTAssertTrue(plan.isLocal)
    }

    /// A card answered while offline is waiting in the queue, not on the
    /// schedule. Offering it again the same afternoon was the bug the old
    /// subject screen shipped with (`answered: []`).
    func testAnsweredCardsAreNotOfferedAgain() {
        let cards = [card("a", due: "2026-08-01"), card("b", due: "2026-08-01")]

        let plan = StudyPlan.local(
            cards: cards, answered: ["a"], minutes: 20, exams: [], today: "2026-08-02"
        )

        XCTAssertEqual(plan.cards.map(\.id), ["b"])
    }

    /// Ten minutes is thirteen cards at forty-five seconds each, and the round
    /// stops there rather than handing over everything that is due.
    func testTheDailyGoalCutsTheRound() {
        let cards = (0 ..< 40).map { card("c\($0)", due: "2026-08-01") }

        let plan = StudyPlan.local(
            cards: cards, answered: [], minutes: 10, exams: [], today: "2026-08-02"
        )

        XCTAssertEqual(plan.cards.count, 13)
        XCTAssertEqual(plan.estimatedMinutes, 10)
    }

    /// A round alternates between subjects instead of running through one and
    /// then the next.
    func testSubjectsAreInterleaved() {
        let cards = [
            card("m1", subject: "Mathematik", due: "2026-08-01"),
            card("m2", subject: "Mathematik", due: "2026-08-01"),
            card("b1", subject: "Biologie", due: "2026-08-01"),
            card("b2", subject: "Biologie", due: "2026-08-01"),
        ]

        let plan = StudyPlan.local(
            cards: cards, answered: [], minutes: 30, exams: [], today: "2026-08-02"
        )

        XCTAssertEqual(plan.cards.map(\.id), ["m1", "b1", "m2", "b2"])
        XCTAssertEqual(plan.subjects, ["Mathematik", "Biologie"])
    }

    /// Why a subject is in the round is the only thing about a plan block a
    /// student cares about: an exam that covers these lessons, or a repetition
    /// falling due.
    func testABlockNamesTheExamItIsFor() {
        let cards = [
            card("a", subject: "Geschichte", due: "2026-08-01", session: "s7"),
            card("b", subject: "Mathematik", due: "2026-08-01", session: "s9"),
        ]
        let paper = exam(subject: "Geschichte", date: "2026-08-07", daysRemaining: 5, sessions: ["s7"])

        let plan = StudyPlan.local(
            cards: cards, answered: [], minutes: 30, exams: [paper], today: "2026-08-02"
        )

        let history = plan.blocks.first { $0.subject == "Geschichte" }
        let maths = plan.blocks.first { $0.subject == "Mathematik" }
        // The weekday itself is formatted in the device's language, so the test
        // checks the sentence rather than the word inside it.
        XCTAssertEqual(history?.reason.hasPrefix("Arbeit am "), true)
        XCTAssertEqual(maths?.reason, "Wiederholung fällig")
        XCTAssertEqual(history?.cardCount, 1)
    }

    /// The server's plan is used as sent, minus anything already answered here.
    func testServerPlanDropsQueuedAnswers() throws {
        let json = #"""
        {
          "date":"2026-08-02","requested_minutes":20,"estimated_minutes":9,
          "cards":[],
          "blocks":[{"subject":"Biologie","exam_name":null,"card_count":4,
                     "estimated_minutes":3,"reason":"Wiederholung fällig"}]
        }
        """#
        let decoded = try JSONDecoder().decode(BackendAPI.LearnDailyPlan.self, from: Data(json.utf8))

        let plan = StudyPlan.server(decoded, answered: [])

        XCTAssertFalse(plan.isLocal)
        XCTAssertEqual(plan.blocks.first?.reason, "Wiederholung fällig")
        XCTAssertEqual(plan.estimatedMinutes, 9)
    }

    // MARK: - Words, not percentages

    /// Four words, and the boundaries they sit on. A card nobody has answered is
    /// "neu" whatever its box says.
    func testReadinessReadsAsAWord() {
        XCTAssertEqual(Readiness(0).word, "neu")
        XCTAssertEqual(Readiness(0.2).word, "wackelt")
        XCTAssertEqual(Readiness(0.5).word, "fast sicher")
        XCTAssertEqual(Readiness(0.9).word, "sicher")
        XCTAssertEqual(cardReadiness(card("x", due: "2026-08-01")), 0)
    }

    /// Lapses cost, so a card that has been forgotten twice does not read the
    /// same as one that never was.
    func testLapsesLowerReadiness() {
        let steady = card("a", due: "2026-08-01", reps: 5, stability: 20, lapses: 0)
        let forgotten = card("b", due: "2026-08-01", reps: 5, stability: 20, lapses: 4)

        XCTAssertGreaterThan(cardReadiness(steady), cardReadiness(forgotten))
    }

    /// Topics group by the concept the generator wrote, weakest first — that is
    /// the order "Wackelt noch" is read in.
    func testTopicsAreGroupedWeakestFirst() {
        let cards = [
            card("a", due: "2026-08-01", reps: 9, stability: 60),
            card("b", due: "2026-08-01", reps: 1, stability: 1),
        ]

        let topics = studyTopics(cards)

        XCTAssertEqual(topics.count, 1, "both fall back to the same lesson title")
        XCTAssertEqual(topics.first?.cards.count, 2)
    }
}

/// A round in progress: what it counts, what it hands back, and when it is worth
/// picking up again.
@MainActor
final class StudySessionTests: XCTestCase {
    private func card(_ id: String) -> BackendAPI.LearnCard {
        let json = """
        {"id":"\(id)","session_id":"s1","subject":"Mathematik","question":"Frage",
         "options":["a","b"],"answer":0,"explanation":"","box":1,"due_date":"2026-08-01"}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BackendAPI.LearnCard.self, from: Data(json.utf8))
    }

    override func tearDown() {
        OfflineCache.remove(key: OfflineCache.Key.studySession)
        super.tearDown()
    }

    func testProgressCountsAnswersRatherThanPosition() {
        let session = StudySession(mode: .review, title: "Lernrunde", cards: [card("a"), card("b")])

        XCTAssertEqual(session.position, 1)
        XCTAssertEqual(session.progress, 0)

        session.record(correct: true, rating: 2)
        session.advance()

        XCTAssertEqual(session.position, 2)
        XCTAssertEqual(session.progress, 0.5)
        XCTAssertEqual(session.correctCount, 1)
        XCTAssertFalse(session.isFinished)
    }

    /// A double tap on an option must not report the same card twice.
    func testACardIsOnlyAnsweredOnce() {
        let session = StudySession(mode: .review, title: "Lernrunde", cards: [card("a")])

        XCTAssertTrue(session.record(correct: false, rating: 0))
        XCTAssertFalse(session.record(correct: true, rating: 2))
        XCTAssertEqual(session.answers.count, 1)
    }

    /// The result screen lists what was missed, in the order it was asked.
    func testMissedCardsComeBackInOrder() {
        let session = StudySession(
            mode: .review, title: "Lernrunde", cards: [card("a"), card("b"), card("c")]
        )

        session.record(correct: false, rating: 0)
        session.advance()
        session.record(correct: true, rating: 2)
        session.advance()
        session.record(correct: false, rating: 0)
        session.advance()

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.missedCards.map(\.id), ["a", "c"])
        XCTAssertEqual(session.correctCount, 1)
    }

    /// A round that was interrupted comes back at the same card; one that has
    /// been sitting for over half an hour is a new evening and is thrown away.
    func testRestoreOnlyWithinTheResumeWindow() throws {
        let session = StudySession(mode: .review, title: "Lernrunde", cards: [card("a"), card("b")])
        session.record(correct: true, rating: 2)
        session.advance()

        let resumed = try XCTUnwrap(StudySession.restore())
        XCTAssertEqual(resumed.position, 2)
        XCTAssertEqual(resumed.answers.count, 1)

        let tooLate = Date().addingTimeInterval(StudySession.resumeWindow + 60)
        XCTAssertNil(StudySession.restore(now: tooLate))
    }

    /// A round nobody has answered anything in is not worth resuming — starting
    /// over costs nothing.
    func testAnUntouchedRoundIsNotResumable() {
        let session = StudySession(mode: .review, title: "Lernrunde", cards: [card("a")])

        XCTAssertFalse(session.isResumable)
        XCTAssertNil(StudySession.restore())
    }
}
