import Foundation

extension BackendAPI {
    /// `Hashable` so an exam can be a navigation destination's value — the row
    /// pushes the exam itself rather than an id the next screen has to look up.
    struct LearnExam: Codable, Sendable, Identifiable, Hashable {
        let id: String
        let name: String
        let subject: String
        let examDate: String
        let scopeStart: String?
        let scopeEnd: String?
        let dailyMinutes: Int
        let target: String?
        let sessionIds: [String]
        let cardCount: Int
        let readiness: Double
        let daysRemaining: Int

        enum CodingKeys: String, CodingKey {
            case id, name, subject, target, readiness
            case examDate = "exam_date"
            case scopeStart = "scope_start"
            case scopeEnd = "scope_end"
            case dailyMinutes = "daily_minutes"
            case sessionIds = "session_ids"
            case cardCount = "card_count"
            case daysRemaining = "days_remaining"
        }
    }

    struct LearnPlanBlock: Codable, Sendable, Equatable, Identifiable {
        let subject: String
        let examName: String?
        let cardCount: Int
        let estimatedMinutes: Int
        let reason: String

        var id: String { "\(subject)|\(examName ?? "daily")" }

        enum CodingKeys: String, CodingKey {
            case subject, reason
            case examName = "exam_name"
            case cardCount = "card_count"
            case estimatedMinutes = "estimated_minutes"
        }
    }

    struct LearnDailyPlan: Codable, Sendable, Equatable {
        let date: String
        let requestedMinutes: Int
        let estimatedMinutes: Int
        let cards: [LearnCard]
        let blocks: [LearnPlanBlock]

        enum CodingKeys: String, CodingKey {
            case date, cards, blocks
            case requestedMinutes = "requested_minutes"
            case estimatedMinutes = "estimated_minutes"
        }
    }

    struct NewLearnExam: Sendable {
        let name: String
        let subject: String
        let examDate: String
        let scopeStart: String?
        let scopeEnd: String?
        let dailyMinutes: Int
        let target: String?
        let sessionIds: [String]
    }

    func learnPlan(minutes: Int) async throws -> LearnDailyPlan {
        let query = [URLQueryItem(name: "minutes", value: String(minutes))]
        return try await JSONDecoder().decode(LearnDailyPlan.self, from: request("/learn/plan", query: query))
    }

    func learnExams() async throws -> [LearnExam] {
        struct Response: Decodable { let exams: [LearnExam] }
        return try await JSONDecoder().decode(Response.self, from: request("/learn/exams")).exams
    }

    func createLearnExam(_ exam: NewLearnExam) async throws -> LearnExam {
        struct Response: Decodable { let exam: LearnExam }
        var body: [String: Any] = [
            "name": exam.name,
            "subject": exam.subject,
            "exam_date": exam.examDate,
            "daily_minutes": exam.dailyMinutes,
            "session_ids": exam.sessionIds,
        ]
        if let value = exam.scopeStart { body["scope_start"] = value }
        if let value = exam.scopeEnd { body["scope_end"] = value }
        if let value = exam.target { body["target"] = value }
        let data = try await request("/learn/exams", method: "POST", jsonBody: body)
        return try JSONDecoder().decode(Response.self, from: data).exam
    }

    func deleteLearnExam(id: String) async throws {
        _ = try await request("/learn/exams/\(id)", method: "DELETE")
    }

    func updateLearnExamSessions(id: String, sessionIds: [String]) async throws -> LearnExam {
        struct Response: Decodable { let exam: LearnExam }
        let data = try await request(
            "/learn/exams/\(id)",
            method: "PATCH",
            jsonBody: ["session_ids": sessionIds]
        )
        return try JSONDecoder().decode(Response.self, from: data).exam
    }
}
