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

    /// Take a manual subject back off a recording, so the timetable names it
    /// again — "Automatisch" in the app. The server keeps a manual subject
    /// protected from auto-labelling, so this is the only way back.
    func clearLessonSubject(sessionId: String) async throws {
        _ = try await request("/sessions/\(sessionId)/subject", method: "DELETE")
    }
}
