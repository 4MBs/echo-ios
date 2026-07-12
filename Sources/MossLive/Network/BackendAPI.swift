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
        let hasAudio: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case startedAtMs = "started_at_ms"
            case endedAtMs = "ended_at_ms"
            case segmentCount = "segment_count"
            case speechSeconds = "speech_seconds"
            case durationSeconds = "duration_seconds"
            case hasSummary = "has_summary"
            case hasAudio = "has_audio"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            startedAtMs = try c.decode(Int64.self, forKey: .startedAtMs)
            endedAtMs = try c.decodeIfPresent(Int64.self, forKey: .endedAtMs)
            segmentCount = try c.decode(Int.self, forKey: .segmentCount)
            speechSeconds = try c.decode(Double.self, forKey: .speechSeconds)
            durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
            hasSummary = try c.decodeIfPresent(Bool.self, forKey: .hasSummary) ?? false
            // tolerate a not-yet-updated server (field added alongside audio recording)
            hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        }

        var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    }

    struct LessonDetail: Decodable, Sendable {
        let id: String
        let startedAtMs: Int64
        let summary: String?
        let hasAudio: Bool
        let segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey {
            case id, summary, segments
            case startedAtMs = "started_at_ms"
            case hasAudio = "has_audio"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            startedAtMs = try c.decode(Int64.self, forKey: .startedAtMs)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
            segments = try c.decode([TranscriptSegment].self, forKey: .segments)
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

    func deleteLesson(id: String) async throws {
        _ = try await request("/sessions/\(id)", method: "DELETE")
    }

    /// Download a lesson's recording to a local cache file (AVAudioPlayer can't
    /// stream an authenticated URL, so we fetch it once and reuse it). The file
    /// is either .m4a or .wav depending on what the server produced.
    func downloadAudio(id: String) async throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lesson-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ext in ["m4a", "wav"] {
            let cached = dir.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
        }
        var req = try URLRequest(url: url("/sessions/\(id)/audio"), timeoutInterval: 120)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tmp, response) = try await URLSession.shared.download(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError(message: "Audio not available (HTTP \(status)).")
        }
        let ext = http?.value(forHTTPHeaderField: "Content-Type") == "audio/wav" ? "wav" : "m4a"
        let dest = dir.appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Remove any cached audio for a deleted lesson.
    static func purgeCachedAudio(id: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lesson-audio", isDirectory: true)
        for ext in ["m4a", "wav"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }
}
