import Foundation

// These wire DTOs intentionally live under BackendAPI, matching every other
// API payload in the app. Their JSON field is named `mastery`, which SwiftLint's
// generic language rule cannot distinguish from the learning-science term.
// swiftlint:disable nesting inclusive_language
extension BackendAPI {
    struct LearnSource: Codable, Hashable, Identifiable, Sendable {
        let sessionId: String
        let lessonTitle: String?
        let sourceLabel: String?
        let sourceStartMs: Int?
        let sourceEndMs: Int?
        let transcriptRevision: Int

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case lessonTitle = "lesson_title"
            case sourceLabel = "source_label"
            case sourceStartMs = "source_start_ms"
            case sourceEndMs = "source_end_ms"
            case transcriptRevision = "transcript_revision"
        }

        var id: String { "\(sessionId)-\(sourceStartMs ?? -1)" }
        var timeSeconds: Double { Double(sourceStartMs ?? 0) / 1000 }
        var displayTitle: String { sourceLabel ?? lessonTitle ?? "Unterrichtsstunde" }
    }

    struct LearnCard: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case multipleChoice = "multiple_choice"
            case trueFalse = "true_false"
            case freeText = "free_text"
            case cloze
            case oral
        }

        let id: String
        let sessionId: String
        let subject: String?
        let lessonTitle: String?
        let question: String
        let options: [String]
        let answer: Int
        let explanation: String
        let kind: Kind
        let expectedAnswer: String?
        let concept: String?
        let difficulty: Int
        let sourceLabel: String?
        let sourceStartMs: Int?
        let sourceEndMs: Int?
        let sourceRevision: Int
        let box: Int
        let dueDate: String
        let stability: Double
        let difficultyScore: Double
        let reps: Int
        let lapses: Int
        let learningState: String?
        let scheduledIntervalDays: Int?
        let successfulRecalls: Int?
        let promptVariant: String?
        let subjectMode: String?
        let answerSpec: LearnAnswerSpec?
        let sources: [LearnSource]

        enum CodingKeys: String, CodingKey {
            case id, subject, question, options, answer, explanation, kind, concept, difficulty
            case box, stability, reps, lapses, sources
            case sessionId = "session_id"
            case lessonTitle = "lesson_title"
            case expectedAnswer = "expected_answer"
            case sourceLabel = "source_label"
            case sourceStartMs = "source_start_ms"
            case sourceEndMs = "source_end_ms"
            case sourceRevision = "source_revision"
            case dueDate = "due_date"
            case difficultyScore = "difficulty_score"
            case learningState = "learning_state"
            case scheduledIntervalDays = "scheduled_interval_days"
            case successfulRecalls = "successful_recalls"
            case promptVariant = "prompt_variant"
            case subjectMode = "subject_mode"
            case answerSpec = "answer_spec"
        }

        var displayConcept: String { concept ?? question }
        var primarySource: LearnSource? { sources.first }
    }

    struct LearnAnswerSpec: Codable, Hashable, Sendable {
        struct Field: Codable, Hashable, Identifiable, Sendable {
            let id: String
            let label: String?
            let expected: String?
        }

        let type: String
        let fields: [Field]?
        let options: [String]?
        let correctIndex: Int?
        let expected: Double?
        let unit: String?
        let tolerance: Double?
        let blanks: [Field]?
        let steps: [String]?

        enum CodingKeys: String, CodingKey {
            case type, fields, options, expected, unit, tolerance, blanks, steps
            case correctIndex = "correct_index"
        }
    }

    struct LearnCardDraft: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var sessionId: String
        var subject: String?
        var lessonTitle: String?
        var question: String
        var options: [String]
        var answer: Int
        var expectedAnswer: String?
        var explanation: String
        var concept: String
        var difficulty: Int
        var kind: LearnCard.Kind
        var sourceLabel: String?
        var sourceStartMs: Int?
        var sourceEndMs: Int?
        var sourceRevision: Int
        var promptVariant: String
        var subjectMode: String
        var answerSpec: LearnAnswerSpec?
        var sources: [LearnSource]

        enum CodingKeys: String, CodingKey {
            case id, subject, question, options, answer, explanation, concept, difficulty, kind, sources
            case sessionId = "session_id"
            case lessonTitle = "lesson_title"
            case expectedAnswer = "expected_answer"
            case sourceLabel = "source_label"
            case sourceStartMs = "source_start_ms"
            case sourceEndMs = "source_end_ms"
            case sourceRevision = "source_revision"
            case promptVariant = "prompt_variant"
            case subjectMode = "subject_mode"
            case answerSpec = "answer_spec"
        }
    }

    struct LearnSubjectSummary: Codable, Hashable, Identifiable, Sendable {
        let subject: String?
        let due: Int
        let newCount: Int?
        let total: Int
        let mastery: Double

        var id: String { subject ?? "" }
        var displayName: String { subject ?? "Sonstige" }

        enum CodingKeys: String, CodingKey {
            case subject, due, total, mastery
            case newCount = "new"
        }
    }

    struct LearnOverview: Codable, Sendable {
        let dueTotal: Int
        let newTotal: Int?
        let cardTotal: Int
        let estimatedMinutes: Int
        let mastery: Double
        let subjects: [LearnSubjectSummary]
        let sessionsWithCards: [String]
        let stateCounts: [String: Int]?
        let overdueTotal: Int?
        let memoryStrength: Double?
        let readiness: Double?
        let readinessStatus: String?

        enum CodingKeys: String, CodingKey {
            case subjects, mastery
            case dueTotal = "due_total"
            case newTotal = "new_total"
            case cardTotal = "card_total"
            case estimatedMinutes = "estimated_minutes"
            case sessionsWithCards = "sessions_with_cards"
            case stateCounts = "state_counts"
            case overdueTotal = "overdue_total"
            case memoryStrength = "memory_strength"
            case readiness, readinessStatus = "readiness_status"
        }
    }

    struct LearnPlan: Codable, Sendable {
        struct Block: Codable, Hashable, Identifiable, Sendable {
            let subject: String
            let examName: String?
            let cardCount: Int
            let estimatedMinutes: Int
            let reason: String

            enum CodingKeys: String, CodingKey {
                case subject, reason
                case examName = "exam_name"
                case cardCount = "card_count"
                case estimatedMinutes = "estimated_minutes"
            }

            var id: String { "\(subject)-\(examName ?? "daily")" }
        }

        let date: String
        let requestedMinutes: Int
        let estimatedMinutes: Int
        let cards: [LearnCard]
        let blocks: [Block]

        enum CodingKeys: String, CodingKey {
            case date, cards, blocks
            case requestedMinutes = "requested_minutes"
            case estimatedMinutes = "estimated_minutes"
        }
    }

    struct LearnEvaluation: Codable, Sendable {
        enum Category: String, Codable, Sendable {
            case correct
            case partial
            case incorrect
            case misconception
        }

        let category: Category
        let feedback: String
        let correctAnswer: String

        enum CodingKeys: String, CodingKey {
            case category, feedback
            case correctAnswer = "correct_answer"
        }
    }

    struct LearnEvaluationResult: Sendable {
        let evaluation: LearnEvaluation
        let card: LearnCard
        let remediation: LearnRemediation?
    }

    struct LearnExam: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let subject: String
        let examDate: String
        let dailyMinutes: Int
        let sessionIds: [String]
        let cardCount: Int
        let readiness: Double?
        let readinessStatus: String?
        let daysRemaining: Int
        let activeRunId: String?

        enum CodingKeys: String, CodingKey {
            case id, name, subject, readiness
            case readinessStatus = "readiness_status"
            case examDate = "exam_date"
            case dailyMinutes = "daily_minutes"
            case sessionIds = "session_ids"
            case cardCount = "card_count"
            case daysRemaining = "days_remaining"
            case activeRunId = "active_run_id"
        }
    }

    struct LearnExamRun: Codable, Identifiable, Sendable {
        struct Result: Codable, Identifiable, Sendable {
            let cardId: String
            let concept: String
            let correct: Bool
            let points: Double
            let maxPoints: Double
            let feedback: String
            var id: String { cardId }

            enum CodingKeys: String, CodingKey {
                case concept, correct, points, feedback
                case cardId = "card_id"
                case maxPoints = "max_points"
            }
        }
        struct Question: Codable, Identifiable, Sendable {
            let id: String
            let question: String
            let concept: String?
            let subject: String?
            let kind: LearnCard.Kind
            let options: [String]
            let difficulty: Int
            let points: Int
            let answerSpec: LearnAnswerSpec?

            enum CodingKeys: String, CodingKey {
                case id, question, concept, subject, kind, options, difficulty, points
                case answerSpec = "answer_spec"
            }
        }

        let id: String
        let examId: String
        let status: String
        let questions: [Question]
        let answers: [String: String]?
        let startedAt: String
        let score: Double?
        let maxPoints: Double
        let timeLimitMinutes: Int
        let pausedSeconds: Int
        let results: [Result]?

        enum CodingKeys: String, CodingKey {
            case id, status, questions, answers, score
            case examId = "exam_id"
            case startedAt = "started_at"
            case maxPoints = "max_points"
            case timeLimitMinutes = "time_limit_minutes"
            case pausedSeconds = "paused_seconds"
            case results
        }
    }

    struct LearnAnalytics: Codable, Sendable {
        struct Activity: Codable, Identifiable, Sendable {
            let date: String
            let count: Int
            var id: String { date }
        }
        struct ResponseTime: Codable, Identifiable, Sendable {
            let date: String
            let averageMs: Int?
            var id: String { date }
            enum CodingKeys: String, CodingKey { case date; case averageMs = "average_ms" }
        }
        let due: Int
        let overdue: Int
        let stateDistribution: [String: Int]
        let recallSuccess: Double?
        let averageResponseMs: Int?
        let lapses: Int
        let repeatedMisconceptions: Int
        let activity7Days: Int
        let activity30Days: Int
        let neverRecalled: [String]
        let recallBySubject: [String: Double]
        let recallByConcept: [String: Double]
        let activitySeries: [Activity]
        let responseTimeSeries: [ResponseTime]

        enum CodingKeys: String, CodingKey {
            case due, overdue, lapses
            case stateDistribution = "state_distribution"
            case recallSuccess = "recall_success"
            case averageResponseMs = "average_response_ms"
            case repeatedMisconceptions = "repeated_misconceptions"
            case activity7Days = "activity_7_days"
            case activity30Days = "activity_30_days"
            case neverRecalled = "never_recalled"
            case recallBySubject = "recall_by_subject"
            case recallByConcept = "recall_by_concept"
            case activitySeries = "activity_series"
            case responseTimeSeries = "response_time_series"
        }
    }

    struct LearnRemediation: Codable, Sendable {
        let diagnosis: String
        let explanation: String
        let hint: String
        let controlQuestion: String
        let expectedAnswer: String
        let promptVariant: String
        let source: LearnSource?

        enum CodingKeys: String, CodingKey {
            case diagnosis, explanation, hint, source
            case controlQuestion = "control_question"
            case expectedAnswer = "expected_answer"
            case promptVariant = "prompt_variant"
        }
    }

    func learnOverview() async throws -> LearnOverview {
        try await JSONDecoder().decode(LearnOverview.self, from: request("/learn/overview"))
    }

    func learnPlan(minutes: Int = 30) async throws -> LearnPlan {
        let query = [URLQueryItem(name: "minutes", value: String(minutes))]
        return try await JSONDecoder().decode(
            LearnPlan.self,
            from: request("/learn/plan", query: query)
        )
    }

    func learnCards(subject: String? = nil) async throws -> [LearnCard] {
        struct Response: Decodable { let cards: [LearnCard] }
        let query = subject.map { [URLQueryItem(name: "subject", value: $0)] }
        return try await JSONDecoder().decode(
            Response.self,
            from: request("/learn/cards", query: query)
        ).cards
    }

    func learnExams() async throws -> [LearnExam] {
        struct Response: Decodable { let exams: [LearnExam] }
        return try await JSONDecoder().decode(Response.self, from: request("/learn/exams")).exams
    }

    func createLearnExam(name: String, subject: String, date: String, sessionIds: [String], dailyMinutes: Int) async throws -> LearnExam {
        struct Response: Decodable { let exam: LearnExam }
        let data = try await request("/learn/exams", method: "POST", jsonBody: [
            "name": name, "subject": subject, "exam_date": date,
            "session_ids": sessionIds, "daily_minutes": dailyMinutes
        ])
        return try JSONDecoder().decode(Response.self, from: data).exam
    }

    func deleteLearnExam(id: String) async throws {
        _ = try await request("/learn/exams/\(id)", method: "DELETE")
    }

    func updateLearnExam(_ exam: LearnExam, name: String, subject: String, date: String, sessionIds: [String], dailyMinutes: Int) async throws -> LearnExam {
        struct Response: Decodable { let exam: LearnExam }
        let data = try await request("/learn/exams/\(exam.id)", method: "PATCH", jsonBody: [
            "name": name, "subject": subject, "exam_date": date,
            "session_ids": sessionIds, "daily_minutes": dailyMinutes
        ])
        return try JSONDecoder().decode(Response.self, from: data).exam
    }

    func startLearnExam(id: String) async throws -> LearnExamRun {
        struct Response: Decodable { let run: LearnExamRun }
        let data = try await request("/learn/exams/\(id)/runs", method: "POST")
        return try JSONDecoder().decode(Response.self, from: data).run
    }

    func learnExamRun(id: String) async throws -> LearnExamRun {
        struct Response: Decodable { let run: LearnExamRun }
        let data = try await request("/learn/exam-runs/\(id)")
        return try JSONDecoder().decode(Response.self, from: data).run
    }

    func saveLearnExamAnswer(runId: String, cardId: String, answer: String) async throws {
        _ = try await request(
            "/learn/exam-runs/\(runId)/answers/\(cardId)", method: "PATCH",
            jsonBody: ["answer": answer]
        )
    }

    func setLearnExamRunStatus(runId: String, status: String) async throws -> LearnExamRun {
        struct Response: Decodable { let run: LearnExamRun }
        let data = try await request(
            "/learn/exam-runs/\(runId)/status", method: "PATCH", jsonBody: ["status": status]
        )
        return try JSONDecoder().decode(Response.self, from: data).run
    }

    func submitLearnExam(runId: String) async throws -> LearnExamRun {
        struct Response: Decodable { let run: LearnExamRun }
        let data = try await request("/learn/exam-runs/\(runId)/submit", method: "POST")
        return try JSONDecoder().decode(Response.self, from: data).run
    }

    func learnAnalytics() async throws -> LearnAnalytics {
        try await JSONDecoder().decode(LearnAnalytics.self, from: request("/learn/analytics"))
    }

    func deleteLearnCard(id: String) async throws {
        _ = try await request("/learn/cards/\(id)", method: "DELETE")
    }

    func generateLearnCards(sessionId: String) async throws -> [LearnCard] {
        struct Response: Decodable { let cards: [LearnCard] }
        let data = try await request(
            "/learn/generate",
            method: "POST",
            jsonBody: ["session_id": sessionId]
        )
        return try JSONDecoder().decode(Response.self, from: data).cards
    }

    func generateLearnDrafts(sessionId: String) async throws -> [LearnCardDraft] {
        struct Response: Decodable { let drafts: [LearnCardDraft] }
        let data = try await request(
            "/learn/generate", method: "POST",
            jsonBody: ["session_id": sessionId, "preview": true]
        )
        return try JSONDecoder().decode(Response.self, from: data).drafts
    }

    func saveLearnDrafts(_ drafts: [LearnCardDraft], sessionId: String) async throws -> [LearnCard] {
        struct Response: Decodable { let cards: [LearnCard] }
        let encoded = try JSONEncoder().encode(drafts)
        let objects = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] ?? []
        let data = try await request(
            "/learn/cards/batch", method: "POST",
            jsonBody: ["session_id": sessionId, "drafts": objects]
        )
        return try JSONDecoder().decode(Response.self, from: data).cards
    }

    func regenerateLearnDraft(_ draft: LearnCardDraft) async throws -> LearnCardDraft {
        struct Response: Decodable { let draft: LearnCardDraft }
        let encoded = try JSONEncoder().encode(draft)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let data = try await request(
            "/learn/drafts/regenerate", method: "POST",
            jsonBody: ["session_id": draft.sessionId, "draft": object]
        )
        return try JSONDecoder().decode(Response.self, from: data).draft
    }

    func updateLearnCard(id: String, draft: LearnCardDraft) async throws -> LearnCard {
        struct Response: Decodable { let card: LearnCard }
        let encoded = try JSONEncoder().encode(draft)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let data = try await request("/learn/cards/\(id)", method: "PATCH", jsonBody: object)
        return try JSONDecoder().decode(Response.self, from: data).card
    }

    func updateLearnCard(id: String, changes: [String: Any]) async throws -> LearnCard {
        struct Response: Decodable { let card: LearnCard }
        let data = try await request("/learn/cards/\(id)", method: "PATCH", jsonBody: changes)
        return try JSONDecoder().decode(Response.self, from: data).card
    }

    func regenerateLearnCard(id: String, concept: String, question: String) async throws -> LearnCard {
        struct Response: Decodable { let card: LearnCard }
        let data = try await request(
            "/learn/cards/\(id)/regenerate", method: "POST",
            jsonBody: ["concept": concept, "question": question]
        )
        return try JSONDecoder().decode(Response.self, from: data).card
    }

    func evaluateLearnAnswer(
        cardId: String,
        answer: String,
        confidence: Int? = nil,
        responseDurationMs: Int? = nil,
        mode: String = "review"
    ) async throws -> LearnEvaluationResult {
        struct Response: Decodable {
            let evaluation: LearnEvaluation
            let card: LearnCard
            let remediation: LearnRemediation?
        }
        var body: [String: Any] = [
            "card_id": cardId, "answer": answer, "attempt_uuid": UUID().uuidString
        ]
        if let confidence { body["confidence"] = confidence }
        if let responseDurationMs { body["response_ms"] = responseDurationMs }
        body["mode"] = mode
        let data = try await request("/learn/evaluate", method: "POST", jsonBody: body)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LearnEvaluationResult(
            evaluation: response.evaluation,
            card: response.card,
            remediation: response.remediation
        )
    }

    func evaluateRemediation(
        cardId: String,
        remediation: LearnRemediation,
        answer: String
    ) async throws -> LearnEvaluationResult {
        struct Response: Decodable {
            let evaluation: LearnEvaluation
            let card: LearnCard
        }
        let body: [String: Any] = [
            "card_id": cardId,
            "question": remediation.controlQuestion,
            "expected_answer": remediation.expectedAnswer,
            "prompt_variant": remediation.promptVariant,
            "answer": answer,
            "attempt_uuid": UUID().uuidString
        ]
        let data = try await request("/learn/remediation/evaluate", method: "POST", jsonBody: body)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LearnEvaluationResult(evaluation: response.evaluation, card: response.card, remediation: nil)
    }
}

// swiftlint:enable nesting inclusive_language
