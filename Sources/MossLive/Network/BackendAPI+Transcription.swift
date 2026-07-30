import CryptoKit
import Foundation

extension BackendAPI {
    struct RetranscriptionStatus: Codable, Sendable, Equatable {
        let status: String
        let offset: Int64
        let size: Int64
        let progress: Double
        let error: String?

        var isFinished: Bool {
            status == "completed"
                || status == "completed_manual_edits_preserved"
                || status == "failed"
        }
    }

    struct TranscriptRevisionInfo: Codable, Identifiable, Sendable {
        let id: Int
        let revision: Int
        let reason: String
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, revision, reason
            case createdAt = "created_at"
        }
    }

    struct TranscriptHistory: Codable, Sendable {
        let currentRevision: Int
        let hasManualEdits: Bool
        let revisions: [TranscriptRevisionInfo]

        enum CodingKeys: String, CodingKey {
            case revisions
            case currentRevision = "current_revision"
            case hasManualEdits = "has_manual_edits"
        }
    }

    struct VocabularyTerm: Codable, Identifiable, Sendable, Equatable {
        let term: String
        let source: String
        let createdAt: String

        var id: String { term.localizedLowercase }

        enum CodingKeys: String, CodingKey {
            case term, source
            case createdAt = "created_at"
        }
    }

    private struct UploadPreparation: Codable {
        let status: String
        let offset: Int64
        let size: Int64
        let progress: Double
        let error: String?
    }

    func retranscriptionStatus(id: String) async throws -> RetranscriptionStatus {
        try await JSONDecoder().decode(
            RetranscriptionStatus.self,
            from: request("/sessions/\(id)/retranscription")
        )
    }

    /// Explicit user action only: resume the safety-file upload, then ask the
    /// backend to start the post-class transcription and wait for its result.
    func manuallyRetranscribe(
        lesson: LessonInfo,
        recording: LocalRecordingSummary,
        onStatus: @MainActor @escaping (RetranscriptionStatus) -> Void
    ) async throws -> RetranscriptionStatus {
        let attributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw APIError(message: "Die Größe der Sicherheitsaufnahme konnte nicht gelesen werden.")
        }
        let size = number.int64Value
        let checksum = try sha256(of: recording.url)
        let lessonStart = lesson.startedAt
        let sourceOffset = max(0, lessonStart.timeIntervalSince(recording.startedAt))
        let duration = lesson.endedAtMs.map {
            max(0.1, Date(timeIntervalSince1970: Double($0) / 1000).timeIntervalSince(lessonStart))
        }
        var preparationBody: [String: Any] = [
            "size": size,
            "sha256": checksum,
            "source_offset_seconds": sourceOffset,
        ]
        if let duration {
            preparationBody["duration_seconds"] = duration
        }
        let preparedData = try await request(
            "/sessions/\(lesson.id)/retranscription/upload",
            method: "POST",
            jsonBody: preparationBody
        )
        var prepared = try JSONDecoder().decode(UploadPreparation.self, from: preparedData)
        await onStatus(
            RetranscriptionStatus(
                status: prepared.status,
                offset: prepared.offset,
                size: prepared.size,
                progress: prepared.progress,
                error: prepared.error
            )
        )

        let handle = try FileHandle(forReadingFrom: recording.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(prepared.offset))
        while prepared.offset < size {
            try Task.checkCancellation()
            let wanted = Int(min(1024 * 1024, size - prepared.offset))
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else {
                throw APIError(message: "Die Sicherheitsaufnahme endete unerwartet.")
            }
            prepared = try await appendUpload(
                lessonId: lesson.id,
                offset: prepared.offset,
                chunk: chunk
            )
            await onStatus(
                RetranscriptionStatus(
                    status: prepared.status,
                    offset: prepared.offset,
                    size: prepared.size,
                    progress: prepared.progress,
                    error: prepared.error
                )
            )
        }

        let startData = try await request("/sessions/\(lesson.id)/retranscribe", method: "POST")
        var state = try JSONDecoder().decode(RetranscriptionStatus.self, from: startData)
        await onStatus(state)
        while !state.isFinished {
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            state = try await retranscriptionStatus(id: lesson.id)
            await onStatus(state)
        }
        if state.status == "failed" {
            throw APIError(message: state.error ?? "Die neue Transkription ist fehlgeschlagen.")
        }
        return state
    }

    func saveTranscript(
        id: String,
        segments: [TranscriptSegment],
        expectedRevision: Int
    ) async throws -> LessonDetail {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(segments)
        let segmentObjects = try JSONSerialization.jsonObject(with: encoded)
        guard let rows = segmentObjects as? [[String: Any]] else {
            throw APIError(message: "Das Transkript konnte nicht vorbereitet werden.")
        }
        struct Response: Decodable {
            let revision: Int
            let hasManualEdits: Bool
            let segments: [TranscriptSegment]

            enum CodingKeys: String, CodingKey {
                case revision, segments
                case hasManualEdits = "has_manual_edits"
            }
        }
        let data = try await request(
            "/sessions/\(id)/transcript",
            method: "PUT",
            jsonBody: ["segments": rows, "expected_revision": expectedRevision]
        )
        let response = try JSONDecoder().decode(Response.self, from: data)
        var current = try await lesson(id: id)
        current.segments = response.segments
        current.transcriptRevision = response.revision
        current.hasManualEdits = response.hasManualEdits
        return current
    }

    func transcriptHistory(id: String) async throws -> TranscriptHistory {
        try await JSONDecoder().decode(
            TranscriptHistory.self,
            from: request("/sessions/\(id)/transcript/history")
        )
    }

    func restoreOriginalTranscript(id: String) async throws -> LessonDetail {
        _ = try await request(
            "/sessions/\(id)/transcript/restore",
            method: "POST",
            jsonBody: ["original": true]
        )
        return try await lesson(id: id)
    }

    func restoreTranscript(id: String, revisionId: Int) async throws -> LessonDetail {
        _ = try await request(
            "/sessions/\(id)/transcript/restore",
            method: "POST",
            jsonBody: ["revision_id": revisionId]
        )
        return try await lesson(id: id)
    }

    func vocabulary(subject: String) async throws -> [VocabularyTerm] {
        struct Response: Decodable {
            let terms: [VocabularyTerm]
        }
        let data = try await request(
            "/vocabulary",
            query: [URLQueryItem(name: "subject", value: subject)]
        )
        return try JSONDecoder().decode(Response.self, from: data).terms
    }

    func addVocabulary(subject: String, terms: [String]) async throws -> [VocabularyTerm] {
        struct Response: Decodable {
            let terms: [VocabularyTerm]
        }
        let data = try await request(
            "/vocabulary",
            method: "POST",
            jsonBody: ["subject": subject, "terms": terms]
        )
        return try JSONDecoder().decode(Response.self, from: data).terms
    }

    func refreshVocabulary(subject: String) async throws -> [VocabularyTerm] {
        struct Response: Decodable {
            let terms: [VocabularyTerm]
        }
        let data = try await request(
            "/vocabulary/refresh",
            method: "POST",
            jsonBody: ["subject": subject]
        )
        return try JSONDecoder().decode(Response.self, from: data).terms
    }

    func deleteVocabulary(subject: String, term: String) async throws {
        _ = try await request(
            "/vocabulary",
            method: "DELETE",
            query: [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "term", value: term),
            ]
        )
    }

    private func appendUpload(
        lessonId: String,
        offset: Int64,
        chunk: Data
    ) async throws -> UploadPreparation {
        var upload = try URLRequest(
            url: url("/sessions/\(lessonId)/retranscription/upload"),
            timeoutInterval: 180
        )
        upload.httpMethod = "PATCH"
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: upload, from: chunk)
        } catch {
            let mapped = await Self.noteOffline(error)
            throw mapped
        }
        await Connectivity.shared.noteReachable()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            struct ErrorBody: Decodable { let error: String? }
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError(message: detail?.error ?? "Upload fehlgeschlagen (HTTP \(status)).", status: status)
        }
        return try JSONDecoder().decode(UploadPreparation.self, from: data)
    }

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
