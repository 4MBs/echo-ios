import Foundation

extension Notification.Name {
    static let pendingNoteImportsChanged = Notification.Name("PendingNoteImportsChanged")
}

/// Durable hand-off from Echo's Share Extension to the main app.
///
/// The extension only copies the original document into the App Group. The
/// user chooses the destination lesson in the full app, where the existing
/// authenticated importer performs all decoding/OCR locally and uploads only
/// the extracted text plus optional page timestamps.
enum PendingNoteImports {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let url: URL
        let filename: String
    }

    enum StorageError: LocalizedError {
        case appGroupUnavailable
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "Die gemeinsame Echo-Ablage ist in dieser Signatur nicht verfügbar."
            case .unreadableFile:
                "Die geteilte Datei konnte nicht gelesen werden."
            }
        }
    }

    private static let directoryName = "PendingNoteImports"

    static func enqueue(from source: URL, suggestedName: String?) throws -> Item {
        let manager = FileManager.default
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw StorageError.unreadableFile }

        let root = try root(create: true)
        let id = UUID().uuidString.lowercased()
        let temporary = root.appendingPathComponent(".\(id).tmp", isDirectory: true)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            let filename = safeFilename(suggestedName, fallback: source.lastPathComponent)
            let copied = temporary.appendingPathComponent(filename, isDirectory: false)
            try manager.copyItem(at: source, to: copied)
            try manager.moveItem(at: temporary, to: destination)
            let item = Item(
                id: id,
                url: destination.appendingPathComponent(filename),
                filename: filename
            )
            NotificationCenter.default.post(name: .pendingNoteImportsChanged, object: nil)
            return item
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func all() -> [Item] {
        guard let root = try? root(create: false),
              let directories = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let file = try? FileManager.default.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: nil,
                      options: [.skipsHiddenFiles]
                  ).first
            else { return nil }
            return Item(id: directory.lastPathComponent, url: file, filename: file.lastPathComponent)
        }
        .sorted { $0.id < $1.id }
    }

    static func remove(_ item: Item) {
        guard let root = try? root(create: false) else { return }
        let directory = root.appendingPathComponent(item.id, isDirectory: true)
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
        NotificationCenter.default.post(name: .pendingNoteImportsChanged, object: nil)
    }

    private static func root(create: Bool) throws -> URL {
        guard let container = SharedConfig.containerURL else { throw StorageError.appGroupUnavailable }
        let root = container.appendingPathComponent(directoryName, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private static func safeFilename(_ suggested: String?, fallback: String) -> String {
        let candidate = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = URL(fileURLWithPath: candidate.isEmpty ? fallback : candidate).lastPathComponent
        guard !basename.isEmpty, basename != "." else { return "Notizen.pdf" }
        let url = URL(fileURLWithPath: basename)
        let suffix = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        guard !suffix.isEmpty else { return String(basename.prefix(240)) }
        let stemLimit = max(1, 239 - suffix.count)
        return "\(stem.prefix(stemLimit)).\(suffix)"
    }
}
