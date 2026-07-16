import Foundation
import os

/// Quick notes ("Notizblock"): sticky notes written by hand during or after
/// class. Stored locally on the device as JSON — they are personal scribbles,
/// not lesson data, so they never touch the server.
@MainActor
@Observable
final class NotesStore {
    struct Note: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var createdAt = Date()
        /// Title of the lesson that was running when the note was taken.
        var lessonTitle: String?
        /// Stable per-note tilt so the board looks hand-arranged.
        var rotationSeed = Double.random(in: -2.2 ... 2.2)
    }

    private(set) var notes: [Note] = []

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "notes")
    @ObservationIgnored private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("notes.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode([Note].self, from: data) {
            notes = stored
        }
    }

    func add(text: String, lessonTitle: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(Note(text: trimmed, lessonTitle: lessonTitle), at: 0)
        save()
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.remove(at: index)
        } else {
            notes[index].text = trimmed
        }
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(notes).write(to: fileURL, options: .atomic)
        } catch {
            log.error("saving notes failed: \(error.localizedDescription)")
        }
    }
}
