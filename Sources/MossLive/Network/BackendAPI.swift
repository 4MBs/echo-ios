import Foundation

/// HTTP client for the backend's lessons archive. Transcripts and summaries
/// live on the Fedora machine — the iPad only ever views them.
struct BackendAPI {
    struct LessonInfo: Codable, Identifiable, Sendable {
        let id: String
        let startedAtMs: Int64
        let endedAtMs: Int64?
        let segmentCount: Int
        let speechSeconds: Double
        let durationSeconds: Double
        let hasSummary: Bool
        /// The opening of the summary, so the lesson list can say what the
        /// lesson was about instead of only when it was.
        let summaryExcerpt: String?
        let hasAudio: Bool
        let title: String?
        let subject: String?
        let teacher: String?
        let room: String?

        enum CodingKeys: String, CodingKey {
            case id, title, subject, teacher, room
            case startedAtMs = "started_at_ms"
            case endedAtMs = "ended_at_ms"
            case segmentCount = "segment_count"
            case speechSeconds = "speech_seconds"
            case durationSeconds = "duration_seconds"
            case hasSummary = "has_summary"
            case summaryExcerpt = "summary_excerpt"
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
            // tolerate a server that predates the lesson list showing previews
            summaryExcerpt = try c.decodeIfPresent(String.self, forKey: .summaryExcerpt)
            // tolerate a not-yet-updated server (field added alongside audio recording)
            hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
            title = try c.decodeIfPresent(String.self, forKey: .title)
            subject = try c.decodeIfPresent(String.self, forKey: .subject)
            teacher = try c.decodeIfPresent(String.self, forKey: .teacher)
            room = try c.decodeIfPresent(String.self, forKey: .room)
        }

        var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    }

    struct LessonDetail: Codable, Sendable {
        let id: String
        let startedAtMs: Int64
        /// Filled in later by "Zusammenfassung erstellen", which is why the
        /// stored copy has to be updatable in place.
        var summary: String?
        let hasAudio: Bool
        let title: String?
        let subject: String?
        let teacher: String?
        let room: String?
        let segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey {
            case id, summary, segments, title, subject, teacher, room
            case startedAtMs = "started_at_ms"
            case hasAudio = "has_audio"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            startedAtMs = try c.decode(Int64.self, forKey: .startedAtMs)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
            title = try c.decodeIfPresent(String.self, forKey: .title)
            subject = try c.decodeIfPresent(String.self, forKey: .subject)
            teacher = try c.decodeIfPresent(String.self, forKey: .teacher)
            room = try c.decodeIfPresent(String.self, forKey: .room)
            segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        }
    }

    // MARK: - Timetable

    struct Lesson: Codable, Identifiable, Sendable, Equatable {
        let date: String
        let start: String
        let end: String
        let startMs: Int64?
        let endMs: Int64?
        let subject: String
        let subjectLong: String?
        let title: String
        let teacher: String
        let room: String
        let cancelled: Bool
        let substitution: Bool
        let info: String

        enum CodingKeys: String, CodingKey {
            case date, start, end, subject, title, teacher, room, cancelled, substitution, info
            case startMs = "start_ms"
            case endMs = "end_ms"
            case subjectLong = "subject_long"
        }

        var id: String { "\(date)-\(start)-\(subject)" }
        var startDate: Date? { startMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        var endDate: Date? { endMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    }

    struct TimetableNow: Codable, Sendable {
        let enabled: Bool
        let current: Lesson?
        let next: Lesson?
    }

    struct TimetableDay: Codable, Sendable {
        let enabled: Bool
        let date: String?
        let lessons: [Lesson]
    }

    /// One subject of the school year — a folder in the Stunden grid.
    struct SubjectInfo: Codable, Identifiable, Sendable, Equatable {
        /// The WebUntis code, e.g. `MAT`.
        let short: String
        /// The name a person would use, when WebUntis carries a separate one.
        let long: String?
        /// What the folder is called — and byte for byte the string a recording
        /// of this subject is labeled with, which is how a folder finds its
        /// recordings without a second lookup.
        let name: String
        let teachers: [String]

        var id: String { name }
    }

    struct APIError: LocalizedError {
        let message: String
        /// Nothing answered at the other end, as opposed to something answering
        /// with bad news. Screens treat the two differently: one falls back to
        /// what is stored on the iPad, the other is a real error worth showing.
        var isOffline = false
        /// The HTTP status, when the server did answer. This is how a screen
        /// tells a refusal it should explain ("this lesson is too short for a
        /// quiz") from a fault it should offer to retry.
        var status: Int?
        var errorDescription: String? { message }
    }

    let host: String
    let port: Int
    let token: String

    // internal: BackendAPI extensions in other files build on this
    func url(_ path: String, query: [URLQueryItem]? = nil) throws -> URL {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = cleanHost
        comps.port = port
        comps.path = path
        comps.queryItems = query
        guard let url = comps.url, !cleanHost.isEmpty else {
            throw APIError(message: "Die Serveradresse ist nicht konfiguriert.")
        }
        return url
    }

    /// Record a transport failure and translate it into something a screen can
    /// recognise. Anything else passes through untouched.
    // internal: BackendAPI extensions in other files build on this
    static func noteOffline(_ error: Error) async -> Error {
        guard Connectivity.meansUnreachable(error) else { return error }
        await Connectivity.shared.note(failure: error)
        return APIError(message: "Keine Verbindung zum Server.", isOffline: true)
    }

    // internal: BackendAPI extensions in other files build on this
    func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem]? = nil,
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        var request = try URLRequest(url: url(path, query: query), timeoutInterval: 100)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let mapped = await Self.noteOffline(error)
            throw mapped
        }
        // Anything with a status line means the server is there, including a
        // 500 — only the transport failing counts as being offline.
        await Connectivity.shared.noteReachable()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            struct ErrorBody: Decodable {
                let error: String?
            }
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError(message: detail ?? "Serverfehler (HTTP \(status)).", status: status)
        }
        return data
    }

    // MARK: - Timetable API

    func timetableNow() async throws -> TimetableNow {
        try await JSONDecoder().decode(TimetableNow.self, from: request("/timetable/now"))
    }

    func timetableDay(date: String? = nil) async throws -> TimetableDay {
        let query = date.map { [URLQueryItem(name: "date", value: $0)] }
        return try await JSONDecoder().decode(TimetableDay.self, from: request("/timetable/day", query: query))
    }

    /// The subjects the Stunden grid draws its folders from. Empty when no
    /// timetable is connected, which leaves the grid to the archive alone.
    func timetableSubjects() async throws -> [SubjectInfo] {
        struct Response: Decodable {
            let subjects: [SubjectInfo]
        }
        let data = try await request("/timetable/subjects")
        return try JSONDecoder().decode(Response.self, from: data).subjects
    }

    func submitWebUntisCredentials(school: String, username: String, password: String) async throws {
        _ = try await request(
            "/timetable/credentials",
            method: "POST",
            jsonBody: ["school": school, "username": username, "password": password]
        )
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

    /// The lesson's audio as peaks in 0…1, for the player's scrubber. The
    /// server derives it from the stored recording, so it exists for lessons
    /// recorded long before the scrubber did.
    func waveform(id: String) async throws -> [Double] {
        struct Response: Decodable {
            let peaks: [Double]
        }
        let data = try await request("/sessions/\(id)/waveform")
        return try JSONDecoder().decode(Response.self, from: data).peaks
    }

    func summarize(id: String) async throws -> String {
        struct Response: Decodable {
            let summary: String
        }
        let data = try await request("/sessions/\(id)/summarize", method: "POST")
        return try JSONDecoder().decode(Response.self, from: data).summary
    }

    /// Same call the stealth widget makes: answer the last seconds of the
    /// currently running recording session.
    func liveAnswer(contextSeconds: Int) async throws -> String {
        struct Response: Decodable {
            let ok: Bool
            let text: String?
        }
        let data = try await request(
            "/answer", method: "POST", jsonBody: ["context_seconds": contextSeconds]
        )
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.ok, let text = response.text, !text.isEmpty else {
            throw APIError(message: "Der Server hat keine Antwort geliefert.")
        }
        return text
    }

    struct ChatTurn: Sendable {
        let role: String // "user" | "assistant"
        let text: String
    }

    /// Ask the AI a free-form question, optionally grounded in the live
    /// session's transcript or a stored lesson.
    func chat(
        question: String,
        history: [ChatTurn],
        sessionId: String? = nil,
        useLive: Bool = false
    ) async throws -> String {
        var body: [String: Any] = [
            "question": question,
            "use_live": useLive,
            "history": history.map { ["role": $0.role, "text": $0.text] },
        ]
        if let sessionId { body["session_id"] = sessionId }
        struct Response: Decodable {
            let ok: Bool
            let text: String?
        }
        let data = try await request("/chat", method: "POST", jsonBody: body)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.ok, let text = response.text else {
            throw APIError(message: "Der Server hat keine Antwort geliefert.")
        }
        return text
    }

    // MARK: - Lernen (spaced repetition)

    struct LearnCard: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let sessionId: String
        let subject: String?
        let lessonTitle: String?
        let question: String
        let options: [String]
        let answer: Int
        let explanation: String
        let box: Int
        let dueDate: String

        enum CodingKeys: String, CodingKey {
            case id, subject, question, options, answer, explanation, box
            case sessionId = "session_id"
            case lessonTitle = "lesson_title"
            case dueDate = "due_date"
        }
    }

    struct LearnSubject: Codable, Sendable, Identifiable, Equatable {
        let subject: String?
        let due: Int
        let total: Int

        var id: String { subject ?? "" }
    }

    struct LearnOverview: Codable, Sendable, Equatable {
        let dueTotal: Int
        let cardTotal: Int
        let subjects: [LearnSubject]
        let sessionsWithCards: [String]

        enum CodingKeys: String, CodingKey {
            case subjects
            case dueTotal = "due_total"
            case cardTotal = "card_total"
            case sessionsWithCards = "sessions_with_cards"
        }
    }

    /// Generate a lesson's card deck (once; later calls return the stored
    /// deck). The backend asks Gemini for exam-relevant questions only.
    func generateCards(sessionId: String) async throws -> [LearnCard] {
        struct Response: Decodable {
            let ok: Bool
            let cards: [LearnCard]?
        }
        let data = try await request("/learn/generate", method: "POST", jsonBody: ["session_id": sessionId])
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.ok, let cards = response.cards, !cards.isEmpty else {
            throw APIError(message: "Quiz konnte nicht erstellt werden.")
        }
        return cards
    }

    func learnOverview() async throws -> LearnOverview {
        try await JSONDecoder().decode(LearnOverview.self, from: request("/learn/overview"))
    }

    private func cardList(_ path: String, subject: String?) async throws -> [LearnCard] {
        struct Response: Decodable {
            let cards: [LearnCard]
        }
        let query = subject.map { [URLQueryItem(name: "subject", value: $0)] }
        return try await JSONDecoder().decode(Response.self, from: request(path, query: query)).cards
    }

    /// Cards due today (or earlier), optionally for one subject.
    func dueCards(subject: String? = nil) async throws -> [LearnCard] {
        try await cardList("/learn/due", subject: subject)
    }

    /// The whole deck, for practice runs that don't touch the schedule.
    func allCards(subject: String? = nil) async throws -> [LearnCard] {
        try await cardList("/learn/cards", subject: subject)
    }

    /// Report one review result; the server reschedules the card.
    func reviewCard(id: String, correct: Bool) async throws {
        _ = try await request(
            "/learn/review", method: "POST", jsonBody: ["card_id": id, "correct": correct]
        )
    }

    func deleteLesson(id: String) async throws {
        _ = try await request("/sessions/\(id)", method: "DELETE")
    }

    /// Download a lesson's recording to a local cache file (AVAudioPlayer can't
    /// stream an authenticated URL, so we fetch it once and reuse it). The file
    /// is either .m4a or .wav depending on what the server produced.
    func downloadAudio(id: String) async throws -> URL {
        let dir = Self.audioDirectory()
        if let cached = Self.cachedAudio(id: id) { return cached }
        var req = try URLRequest(url: url("/sessions/\(id)/audio"), timeoutInterval: 120)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await URLSession.shared.download(for: req)
        } catch {
            let mapped = await Self.noteOffline(error)
            throw mapped
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError(message: "Audio nicht verfügbar (HTTP \(status)).")
        }
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ext = contentType.contains("wav") ? "wav" : "m4a"
        let dest = dir.appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private static func audioDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lesson-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The already-downloaded recording of a lesson, if there is one — which is
    /// what decides whether the player is worth offering while offline.
    static func cachedAudio(id: String) -> URL? {
        let dir = audioDirectory()
        for ext in ["m4a", "wav"] {
            let cached = dir.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
        }
        return nil
    }

    /// Remove any cached audio for a deleted lesson.
    static func purgeCachedAudio(id: String) {
        let dir = audioDirectory()
        for ext in ["m4a", "wav"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }
}
