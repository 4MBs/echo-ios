import Foundation
import Observation

/// Persistent, multi-conversation state for "Chat mit KI".
///
/// The server still owns inference and transcript grounding. This store owns
/// the pieces that make the chat feel like a real conversation on the device:
/// history, attachments, editing, retrying, cancellation and durable titles.
@MainActor
@Observable
final class ChatStore {
    enum Role: String, Codable, Sendable {
        case user, assistant
    }

    struct Attachment: Identifiable, Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case image, document

            var systemImage: String {
                switch self {
                case .image: "photo"
                case .document: "doc.text"
                }
            }
        }

        let id: UUID
        let kind: Kind
        let fileName: String
        let mimeType: String
        let byteCount: Int
        let thumbnailData: Data?
        let extractedText: String

        /// Kept only until the message is sent. Conversation persistence stores
        /// the small thumbnail and extracted text, never a full private photo.
        var uploadData: Data?

        init(
            id: UUID = UUID(),
            kind: Kind,
            fileName: String,
            mimeType: String,
            byteCount: Int,
            thumbnailData: Data? = nil,
            extractedText: String = "",
            uploadData: Data? = nil
        ) {
            self.id = id
            self.kind = kind
            self.fileName = fileName
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.thumbnailData = thumbnailData
            self.extractedText = extractedText
            self.uploadData = uploadData
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, fileName, mimeType, byteCount, thumbnailData, extractedText
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            kind = try values.decode(Kind.self, forKey: .kind)
            fileName = try values.decode(String.self, forKey: .fileName)
            mimeType = try values.decode(String.self, forKey: .mimeType)
            byteCount = try values.decode(Int.self, forKey: .byteCount)
            thumbnailData = try values.decodeIfPresent(Data.self, forKey: .thumbnailData)
            extractedText = try values.decodeIfPresent(String.self, forKey: .extractedText) ?? ""
            uploadData = nil
        }
    }

    struct Message: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let role: Role
        var text: String
        let date: Date
        var attachments: [Attachment]
        var usedWebSearch: Bool

        init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            date: Date = Date(),
            attachments: [Attachment] = [],
            usedWebSearch: Bool = false
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.date = date
            self.attachments = attachments
            self.usedWebSearch = usedWebSearch
        }
    }

    /// What the AI is grounded in for the next question.
    enum Context: Codable, Equatable, Sendable {
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

    struct Conversation: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        var title: String
        var messages: [Message]
        var context: Context
        let createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            title: String = "Neue Unterhaltung",
            messages: [Message] = [],
            context: Context = .none,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.messages = messages
            self.context = context
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    private struct SavedState: Codable, Sendable {
        var conversations: [Conversation]
        var selectedConversationID: UUID
    }

    /// JSON encoding and atomic file replacement can be noticeable once a
    /// conversation contains thumbnails and long extracted documents. Keep it
    /// serial and off the main actor; revisions prevent a late older task from
    /// overwriting a newer snapshot.
    private actor PersistenceWriter {
        private var newestRevision = 0

        func save(_ state: SavedState, revision: Int, key: String) {
            guard revision >= newestRevision else { return }
            newestRevision = revision
            OfflineCache.save(state, as: key)
        }
    }

    private static let storageKey = "chat-conversations-v2"

    private(set) var conversations: [Conversation]
    private(set) var selectedConversationID: UUID
    private(set) var sending = false
    var errorMessage: String?

    private let persistenceEnabled: Bool
    @ObservationIgnored private let persistenceWriter = PersistenceWriter()
    @ObservationIgnored private var persistenceRevision = 0
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    init(loadPersisted: Bool = true) {
        persistenceEnabled = loadPersisted
        if UITestRuntime.isEnabled, UITestRuntime.scenario != .empty {
            conversations = Self.uiTestConversations
            selectedConversationID = conversations[0].id
        } else if loadPersisted,
           let saved = OfflineCache.load(SavedState.self, key: Self.storageKey),
           !saved.conversations.isEmpty {
            let restored = saved.conversations.sorted { $0.updatedAt > $1.updatedAt }
            let restoredSelection = restored.contains(where: { $0.id == saved.selectedConversationID })
                ? saved.selectedConversationID
                : restored[0].id
            conversations = restored
            selectedConversationID = restoredSelection
        } else {
            let conversation = Conversation()
            conversations = [conversation]
            selectedConversationID = conversation.id
        }
    }

    var currentConversation: Conversation {
        conversations[currentIndex]
    }

    var messages: [Message] {
        conversations[currentIndex].messages
    }

    var context: Context {
        get { conversations[currentIndex].context }
        set {
            conversations[currentIndex].context = newValue
            touchCurrentConversation()
        }
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        cancel()
        selectedConversationID = id
        errorMessage = nil
        persist()
    }

    func createConversation(context: Context = .none) {
        cancel()
        if messages.isEmpty {
            self.context = context
            return
        }
        let conversation = Conversation(context: context)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        errorMessage = nil
        persist()
    }

    func rename(_ id: UUID, to proposedTitle: String) {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(title.prefix(80))
        conversations[index].updatedAt = Date()
        sortConversationsKeepingSelection()
        persist()
    }

    func delete(_ id: UUID) {
        if selectedConversationID == id { cancel() }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let conversation = Conversation()
            conversations = [conversation]
            selectedConversationID = conversation.id
        } else if !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations[0].id
        }
        errorMessage = nil
        persist()
    }

    func clear() {
        cancel()
        conversations[currentIndex].messages = []
        conversations[currentIndex].title = "Neue Unterhaltung"
        conversations[currentIndex].updatedAt = Date()
        errorMessage = nil
        persist()
    }

    func send(
        question: String,
        attachments: [Attachment] = [],
        webSearch: Bool = false,
        api: BackendAPI
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !sending else { return }

        let visibleQuestion = trimmed.isEmpty ? "Analysiere die Anhänge." : trimmed
        let history = backendHistory(from: messages)
        let user = Message(
            role: .user,
            text: visibleQuestion,
            attachments: attachments,
            usedWebSearch: webSearch
        )
        conversations[currentIndex].messages.append(user)
        if conversations[currentIndex].messages.count == 1 {
            conversations[currentIndex].title = Self.title(for: visibleQuestion, attachments: attachments)
        }
        touchCurrentConversation()
        startRequest(for: user, history: history, api: api)
    }

    func resend(_ userMessageID: UUID, api: BackendAPI) {
        guard !sending,
              let index = messages.firstIndex(where: { $0.id == userMessageID && $0.role == .user })
        else { return }
        let user = messages[index]
        let history = backendHistory(from: Array(messages[..<index]))
        conversations[currentIndex].messages = Array(messages[...index])
        touchCurrentConversation()
        startRequest(for: user, history: history, resetNativeThread: true, api: api)
    }

    func editAndResend(_ userMessageID: UUID, text: String, api: BackendAPI) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending,
              let index = messages.firstIndex(where: { $0.id == userMessageID && $0.role == .user })
        else { return }
        var user = messages[index]
        user.text = trimmed
        let history = backendHistory(from: Array(messages[..<index]))
        conversations[currentIndex].messages = Array(messages[..<index]) + [user]
        if index == 0 {
            conversations[currentIndex].title = Self.title(for: trimmed, attachments: user.attachments)
        }
        touchCurrentConversation()
        startRequest(for: user, history: history, resetNativeThread: true, api: api)
    }

    func regenerate(after assistantMessageID: UUID, api: BackendAPI) {
        guard !sending,
              let assistantIndex = messages.firstIndex(where: {
                  $0.id == assistantMessageID && $0.role == .assistant
              }),
              let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user })
        else { return }
        let user = messages[userIndex]
        let history = backendHistory(from: Array(messages[..<userIndex]))
        conversations[currentIndex].messages = Array(messages[...userIndex])
        touchCurrentConversation()
        startRequest(for: user, history: history, resetNativeThread: true, api: api)
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        activeRequestID = nil
        sending = false
    }

    private func startRequest(
        for user: Message,
        history: [BackendAPI.ChatTurn],
        resetNativeThread: Bool = false,
        api: BackendAPI
    ) {
        errorMessage = nil
        sending = true
        let requestID = UUID()
        activeRequestID = requestID
        let selectedID = selectedConversationID
        let requestContext = context
        let payloads = user.attachments.map {
            BackendAPI.ChatAttachment(
                kind: $0.kind.rawValue,
                fileName: $0.fileName,
                mimeType: $0.mimeType,
                dataBase64: $0.uploadData?.base64EncodedString(),
                extractedText: $0.extractedText
            )
        }

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: String = switch requestContext {
                case .live:
                    try await api.chat(
                        question: user.text,
                        history: history,
                        conversationId: selectedID,
                        useLive: true,
                        attachments: payloads,
                        webSearch: user.usedWebSearch,
                        resetNativeThread: resetNativeThread
                    )
                case .lesson(let id, _):
                    try await api.chat(
                        question: user.text,
                        history: history,
                        conversationId: selectedID,
                        sessionId: id,
                        attachments: payloads,
                        webSearch: user.usedWebSearch,
                        resetNativeThread: resetNativeThread
                    )
                case .none:
                    try await api.chat(
                        question: user.text,
                        history: history,
                        conversationId: selectedID,
                        attachments: payloads,
                        webSearch: user.usedWebSearch,
                        resetNativeThread: resetNativeThread
                    )
                }
                guard !Task.isCancelled,
                      self.activeRequestID == requestID,
                      let index = self.conversations.firstIndex(where: { $0.id == selectedID })
                else { return }
                if UITestRuntime.isEnabled {
                    let messageID = UUID()
                    self.conversations[index].messages.append(
                        Message(id: messageID, role: .assistant, text: "")
                    )
                    let words = answer.split(separator: " ", omittingEmptySubsequences: false)
                    for (wordIndex, word) in words.enumerated() {
                        try await Task.sleep(for: .milliseconds(28))
                        guard !Task.isCancelled,
                              self.activeRequestID == requestID,
                              let conversationIndex = self.conversations.firstIndex(where: { $0.id == selectedID }),
                              let messageIndex = self.conversations[conversationIndex].messages.firstIndex(
                                  where: { $0.id == messageID }
                              )
                        else { return }
                        if wordIndex > 0 {
                            self.conversations[conversationIndex].messages[messageIndex].text += " "
                        }
                        self.conversations[conversationIndex].messages[messageIndex].text += word
                    }
                } else {
                    self.conversations[index].messages.append(Message(role: .assistant, text: answer))
                }
                self.conversations[index].updatedAt = Date()
                self.finishRequest(requestID)
            } catch is CancellationError {
                self.finishRequest(requestID)
            } catch {
                guard self.activeRequestID == requestID else { return }
                self.errorMessage = error.localizedDescription
                self.finishRequest(requestID)
            }
        }
    }

    private func finishRequest(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        requestTask = nil
        sending = false
        sortConversationsKeepingSelection()
        persist()
    }

    private func touchCurrentConversation() {
        conversations[currentIndex].updatedAt = Date()
        sortConversationsKeepingSelection()
        persist()
    }

    private func sortConversationsKeepingSelection() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private var currentIndex: Int {
        conversations.firstIndex(where: { $0.id == selectedConversationID }) ?? 0
    }

    private func backendHistory(from messages: [Message]) -> [BackendAPI.ChatTurn] {
        messages.suffix(10).map {
            BackendAPI.ChatTurn(
                role: $0.role.rawValue,
                text: Self.serverText(for: $0)
            )
        }
    }

    private static func serverText(for message: Message) -> String {
        let attachmentText = message.attachments.compactMap { attachment -> String? in
            let text = attachment.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "Anhang \(attachment.fileName):\n\(text.prefix(12000))"
        }.joined(separator: "\n\n")
        guard !attachmentText.isEmpty else { return message.text }
        return "\(message.text)\n\n\(attachmentText)"
    }

    private static func title(for question: String, attachments: [Attachment]) -> String {
        let normalized = question
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if normalized == "Analysiere die Anhänge.", let first = attachments.first {
            return String(first.fileName.prefix(52))
        }
        let prefix = normalized.prefix(52)
        return prefix.count < normalized.count ? "\(prefix)…" : String(prefix)
    }

    private func persist() {
        guard persistenceEnabled else { return }
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = SavedState(
            conversations: conversations,
            selectedConversationID: selectedConversationID
        )
        Task { [persistenceWriter] in
            await persistenceWriter.save(snapshot, revision: revision, key: Self.storageKey)
        }
    }

    private static var uiTestConversations: [Conversation] {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let base = Date(timeIntervalSince1970: 1_775_702_400)
        let longSuffix = UITestRuntime.scenario == .longContent
            ? String(repeating: " Dieser lange Absatz prüft Umbruch, Scrollen und dynamische Textgrößen.", count: 18)
            : ""
        let attachment = Attachment(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            kind: .document,
            fileName: "Versuchsprotokoll.pdf",
            mimeType: "application/pdf",
            byteCount: 42_000,
            extractedText: "Beobachtung: Der Test ist reproduzierbar."
        )
        return [
            Conversation(
                id: firstID,
                title: "Ursache und Wirkung",
                messages: [
                    Message(role: .user, text: "Erkläre Ursache und Wirkung.", date: base),
                    Message(
                        role: .assistant,
                        text: "Eine Ursache löst unter bestimmten Bedingungen eine Wirkung aus.\(longSuffix)",
                        date: base.addingTimeInterval(1)
                    ),
                    Message(
                        role: .user,
                        text: "Beziehe das Dokument ein.",
                        date: base.addingTimeInterval(2),
                        attachments: [attachment]
                    ),
                    Message(
                        role: .assistant,
                        text: "Das Versuchsprotokoll bestätigt den reproduzierbaren Zusammenhang.",
                        date: base.addingTimeInterval(3)
                    ),
                ],
                context: .lesson(id: "lesson-1", title: "Teststunde Mathematik"),
                createdAt: base,
                updatedAt: base.addingTimeInterval(3)
            ),
            Conversation(
                id: secondID,
                title: "Ohne Kontext",
                messages: [
                    Message(role: .user, text: "Was kannst du?", date: base.addingTimeInterval(-60)),
                    Message(role: .assistant, text: "Ich helfe beim Lernen.", date: base.addingTimeInterval(-59)),
                ],
                context: .none,
                createdAt: base.addingTimeInterval(-60),
                updatedAt: base.addingTimeInterval(-59)
            ),
        ]
    }
}
