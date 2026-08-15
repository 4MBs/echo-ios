import Foundation

/// One privacy-preserving path for files selected inside Echo and files sent
/// by another app. The original document is decoded locally; the server only
/// receives extracted text and optional page timestamps.
enum LessonNoteImportService {
    static func importDocument(
        at url: URL,
        filename: String,
        importID: String? = nil,
        sessionID: String,
        api: BackendAPI
    ) async throws -> BackendAPI.NoteImportResult {
        let extraction = try await LocalNoteImporter.extract(from: url)
        let result = try await api.importLessonNotes(
            sessionId: sessionID,
            originalFilename: filename,
            pages: extraction.pages,
            importID: importID
        )
        return BackendAPI.NoteImportResult(
            notes: result.notes,
            warnings: Array(Set(extraction.warnings + result.warnings)).sorted()
        )
    }
}
