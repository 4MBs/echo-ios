import Foundation

extension BackendAPI {
    struct LessonNote: Codable, Identifiable, Sendable, Equatable {
        let id: String
        let sessionId: String
        let offsetSeconds: Double
        let kind: String
        let timingSource: String
        let title: String
        let textContent: String
        let originalFilename: String?
        let mimeType: String?
        let hasAttachment: Bool
        let createdAt: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, kind, title
            case sessionId = "session_id"
            case offsetSeconds = "offset_seconds"
            case timingSource = "timing_source"
            case textContent = "text_content"
            case originalFilename = "original_filename"
            case mimeType = "mime_type"
            case hasAttachment = "has_attachment"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct NoteImportResult: Sendable {
        let notes: [LessonNote]
        let warnings: [String]
    }

    func lessonNotes(id: String) async throws -> [LessonNote] {
        struct Response: Decodable {
            let notes: [LessonNote]
        }
        let data = try await request("/sessions/\(id)/notes")
        return try JSONDecoder().decode(Response.self, from: data).notes
    }

    func importLessonNotes(
        sessionId: String,
        originalFilename: String,
        pages: [LocalNotePage]
    ) async throws -> NoteImportResult {
        guard !pages.isEmpty else {
            throw APIError(message: "Das Dokument enthält keine importierbaren Seiten.")
        }
        let textBytes = pages.reduce(0) { $0 + $1.text.utf8.count }
        guard pages.count <= 2000, textBytes <= 4_000_000 else {
            throw APIError(message: "Der lokal extrahierte Notiztext ist zu groß.")
        }
        let importId = UUID().uuidString.lowercased()
        let query = [
            URLQueryItem(name: "filename", value: originalFilename),
            URLQueryItem(name: "import_id", value: importId),
        ]
        var upload = try URLRequest(
            url: url("/sessions/\(sessionId)/notes/import", query: query),
            timeoutInterval: 240
        )
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct TextOnlyImport: Encodable {
            let privacy: String
            let pages: [LocalNotePage]
        }
        upload.httpBody = try JSONEncoder().encode(TextOnlyImport(privacy: "text_only", pages: pages))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: upload)
        } catch {
            throw await Self.noteOffline(error)
        }
        await Connectivity.shared.noteReachable()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            struct ErrorBody: Decodable {
                let error: String?
            }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Notizimport fehlgeschlagen (HTTP \(status))."
            throw APIError(message: message, status: status)
        }
        struct Response: Decodable {
            let notes: [LessonNote]
            let warnings: [String]?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return NoteImportResult(notes: decoded.notes, warnings: decoded.warnings ?? [])
    }

    func deleteLessonNote(sessionId: String, noteId: String) async throws {
        _ = try await request("/sessions/\(sessionId)/notes/\(noteId)", method: "DELETE")
    }

    func downloadLessonNoteAttachment(sessionId: String, noteId: String) async throws -> URL {
        var download = try URLRequest(
            url: url("/sessions/\(sessionId)/notes/\(noteId)/attachment"),
            timeoutInterval: 180
        )
        download.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(for: download)
        } catch {
            throw await Self.noteOffline(error)
        }
        await Connectivity.shared.noteReachable()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError(message: "Notizdatei nicht verfügbar (HTTP \(status)).", status: status)
        }
        let suggested = response.suggestedFilename ?? "\(noteId).bin"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(suggested)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
