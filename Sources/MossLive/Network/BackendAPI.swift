import Foundation

/// HTTP client for the backend's lessons archive. Transcripts and summaries
/// live on the Fedora machine — the iPad only ever views them.
struct BackendAPI {
    struct LessonInfo: Decodable, Identifiable, Sendable {
        let id: String
        let startedAtMs: Int64
        let endedAtMs: Int64?
        let segmentCount: Int
        let speechSeconds: Double
        let durationSeconds: Double
        let hasSummary: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case startedAtMs = "started_at_ms"
            case endedAtMs = "ended_at_ms"
            case segmentCount = "segment_count"
            case speechSeconds = "speech_seconds"
            case durationSeconds = "duration_seconds"
            case hasSummary = "has_summary"
        }

        var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    }

    struct LessonDetail: Decodable, Sendable {
        let id: String
        let startedAtMs: Int64
        let summary: String?
        let segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey {
            case id, summary, segments
            case startedAtMs = "started_at_ms"
        }
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let host: String
    let port: Int
    let token: String

    private func url(_ path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host.trimmingCharacters(in: .whitespaces)
        comps.port = port
        comps.path = path
        guard let url = comps.url, !host.isEmpty else {
            throw APIError(message: "Server address is not configured.")
        }
        return url
    }

    private func request(_ path: String, method: String = "GET") async throws -> Data {
        var request = try URLRequest(url: url(path), timeoutInterval: 100)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            struct ErrorBody: Decodable {
                let error: String?
            }
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError(message: detail ?? "Server error (HTTP \(status)).")
        }
        return data
    }

    func listLessons() async throws -> [LessonInfo] {
        struct Response: Decodable {
            let sessions: [LessonInfo]
        }
        let data = try await request("/sessions")
        return try JSONDecoder().decode(Response.self, from: data).sessions
    }

    func lesson(id: String) async throws -> LessonDetail {
        try await JSONDecoder().decode(LessonDetail.self, from: request("/sessions/\(id)"))
    }

    func summarize(id: String) async throws -> String {
        struct Response: Decodable {
            let summary: String
        }
        let data = try await request("/sessions/\(id)/summarize", method: "POST")
        return try JSONDecoder().decode(Response.self, from: data).summary
    }
}
