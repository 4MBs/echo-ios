import Foundation
import Observation

/// Chat mit KI: message list + sending state. Lives on the AppModel so the
/// conversation survives switching sidebar tabs (in memory, per app run).
@MainActor
@Observable
final class ChatStore {
    enum Role {
        case user, assistant
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let text: String
        let date = Date()
    }

    /// What the AI is grounded in for the next question.
    enum Context: Equatable {
        case live
        case lesson(id: String, title: String)
        case none

        var label: String {
            switch self {
            case .live: "Aktuelle Aufnahme"
            case .lesson(_, let title): title
            case .none: "Ohne Kontext"
            }
        }
    }

    private(set) var messages: [Message] = []
    private(set) var sending = false
    var context: Context = .none
    var errorMessage: String?

    func send(question: String, api: BackendAPI) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        errorMessage = nil
        // history *before* the new question, so the server sees it separately
        let history = messages.suffix(10).map {
            BackendAPI.ChatTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text)
        }
        messages.append(Message(role: .user, text: trimmed))
        sending = true
        defer { sending = false }
        do {
            let answer: String = switch context {
            case .live:
                try await api.chat(question: trimmed, history: history, useLive: true)
            case .lesson(let id, _):
                try await api.chat(question: trimmed, history: history, sessionId: id)
            case .none:
                try await api.chat(question: trimmed, history: history)
            }
            messages.append(Message(role: .assistant, text: answer))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        messages = []
        errorMessage = nil
    }
}
