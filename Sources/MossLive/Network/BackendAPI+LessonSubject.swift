import Foundation

extension BackendAPI {
    func updateLessonSubject(sessionId: String, subject: String) async throws -> LessonDetail {
        struct Response: Decodable { let session: LessonDetail }
        let data = try await request(
            "/sessions/\(sessionId)/subject",
            method: "PATCH",
            jsonBody: ["subject": subject]
        )
        return try JSONDecoder().decode(Response.self, from: data).session
    }
}
