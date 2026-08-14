import Foundation

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
        }

        var displayConcept: String { concept ?? question }
        var primarySource: LearnSource? { sources.first }
    }

    struct LearnSubjectSummary: Codable, Hashable, Identifiable, Sendable {
        let subject: String?
        let due: Int
        let total: Int
        let mastery: Double

        var id: String { subject ?? "" }
        var displayName: String { subject ?? "Sonstige" }
    }

    struct LearnOverview: Codable, Sendable {
        let dueTotal: Int
        let cardTotal: Int
        let estimatedMinutes: Int
        let mastery: Double
        let subjects: [LearnSubjectSummary]
        let sessionsWithCards: [String]

        enum CodingKeys: String, CodingKey {
            case subjects, mastery
            case dueTotal = "due_total"
            case cardTotal = "card_total"
            case estimatedMinutes = "estimated_minutes"
            case sessionsWithCards = "sessions_with_cards"
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

    func generateLearnCards(sessionId: String) async throws -> [LearnCard] {
        struct Response: Decodable { let cards: [LearnCard] }
        let data = try await request(
            "/learn/generate",
            method: "POST",
            jsonBody: ["session_id": sessionId]
        )
        return try JSONDecoder().decode(Response.self, from: data).cards
    }

    func evaluateLearnAnswer(
        cardId: String,
        answer: String,
        confidence: Int? = nil
    ) async throws -> LearnEvaluationResult {
        struct Response: Decodable {
            let evaluation: LearnEvaluation
            let card: LearnCard
        }
        var body: [String: Any] = ["card_id": cardId, "answer": answer]
        if let confidence { body["confidence"] = confidence }
        let data = try await request("/learn/evaluate", method: "POST", jsonBody: body)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LearnEvaluationResult(evaluation: response.evaluation, card: response.card)
    }
}
