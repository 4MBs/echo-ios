import Foundation
import Observation

@MainActor
@Observable
final class IncomingNoteImportCoordinator {
    enum Status: Equatable {
        case idle
        case waiting(String)
        case importing(String)
        case success(String)
        case failure(PendingNoteImports.Item?, String)

        var message: String? {
            switch self {
            case .idle: nil
            case .waiting: "Datei wartet auf Verbindung"
            case .importing: "Datei wird hinzugefügt…"
            case .success: "Datei hinzugefügt"
            case .failure(_, let message): message
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    private(set) var destinationItem: PendingNoteImports.Item?
    private(set) var completedLesson: BackendAPI.LessonInfo?
    private(set) var status: Status = .idle
    private var waitingItem: PendingNoteImports.Item?
    private var importTask: Task<Void, Never>?
    private var statusDismissTask: Task<Void, Never>?

    func receive(_ url: URL, model: AppModel) {
        do {
            let item: PendingNoteImports.Item
            if url.scheme?.lowercased() == "echo" {
                guard url.host == "note-import",
                      let id = url.pathComponents.last,
                      let pending = PendingNoteImports.item(id: id)
                else {
                    throw IncomingError.missingPendingFile
                }
                item = pending
            } else {
                guard url.isFileURL else { throw IncomingError.unsupportedURL }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                item = try PendingNoteImports.enqueue(
                    from: url,
                    suggestedName: url.lastPathComponent
                )
            }
            route(item, model: model)
        } catch {
            status = .failure(nil, error.localizedDescription)
        }
    }

    func modelDidChange(_ model: AppModel) {
        guard let item = waitingItem else { return }
        if model.recordingStartedAt == nil {
            waitingItem = nil
            presentDestination(for: item, model: model)
        } else if let sessionID = model.sessionId {
            waitingItem = nil
            importIntoActiveRecording(item, sessionID: sessionID, api: model.api)
        }
    }

    func importIntoSelectedLesson(
        _ lesson: BackendAPI.LessonInfo,
        item: PendingNoteImports.Item,
        api: BackendAPI
    ) {
        startImport(item, sessionID: lesson.id, api: api) { [weak self] in
            self?.completedLesson = lesson
            self?.showSuccess()
        }
    }

    func retry(model: AppModel) {
        guard case .failure(let item?, _) = status else { return }
        route(item, model: model)
    }

    func dismissStatus() {
        statusDismissTask?.cancel()
        statusDismissTask = nil
        status = .idle
    }

    func destinationSheetDismissed() {
        destinationItem = nil
        completedLesson = nil
    }

    private func route(_ item: PendingNoteImports.Item, model: AppModel) {
        if model.recordingStartedAt != nil {
            if let sessionID = model.sessionId {
                importIntoActiveRecording(item, sessionID: sessionID, api: model.api)
            } else {
                waitingItem = item
                status = .waiting(item.filename)
            }
        } else {
            presentDestination(for: item, model: model)
        }
    }

    private func presentDestination(for item: PendingNoteImports.Item, model: AppModel) {
        destinationItem = item
        completedLesson = nil
        status = .idle
        model.selectedTab = .stunden
    }

    private func importIntoActiveRecording(
        _ item: PendingNoteImports.Item,
        sessionID: String,
        api: BackendAPI
    ) {
        startImport(item, sessionID: sessionID, api: api) { [weak self] in
            self?.showSuccess()
        }
    }

    private func startImport(
        _ item: PendingNoteImports.Item,
        sessionID: String,
        api: BackendAPI,
        completion: @escaping @MainActor () -> Void
    ) {
        guard importTask == nil else {
            status = .failure(item, "Ein anderes Dokument wird gerade importiert. Versuche es gleich erneut.")
            return
        }
        statusDismissTask?.cancel()
        statusDismissTask = nil
        status = .importing(item.filename)
        importTask = Task { [weak self] in
            defer { self?.importTask = nil }
            do {
                _ = try await LessonNoteImportService.importDocument(
                    at: item.url,
                    filename: item.filename,
                    importID: item.id,
                    sessionID: sessionID,
                    api: api
                )
                PendingNoteImports.remove(item)
                completion()
            } catch {
                self?.status = .failure(item, error.localizedDescription)
            }
        }
    }

    private func showSuccess() {
        statusDismissTask?.cancel()
        status = .success("Datei hinzugefügt")
        statusDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard self?.status == .success("Datei hinzugefügt") else { return }
            self?.status = .idle
            self?.statusDismissTask = nil
        }
    }

    private enum IncomingError: LocalizedError {
        case missingPendingFile
        case unsupportedURL

        var errorDescription: String? {
            switch self {
            case .missingPendingFile: "Die geteilte Datei ist nicht mehr in Echo verfügbar."
            case .unsupportedURL: "Dieser geteilte Inhalt ist keine unterstützte Datei."
            }
        }
    }
}
