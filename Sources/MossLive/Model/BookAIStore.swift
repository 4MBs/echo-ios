import Foundation
import Observation

/// Persistent, multi-conversation state for the assistant inside one book.
///
/// Page and region selection describe the context of the next request. They do
/// not own the conversation: removing a marked rectangle or turning a page must
/// never make an existing exchange disappear. Each completed turn remembers
/// the exact context it used so retrying it remains grounded in the same place.
@MainActor
@Observable
final class BookAIStore {
    struct Context: Codable, Hashable, Sendable {
        let pages: [Int]
        let region: BackendAPI.BookPageRegion?

        init(pages: [Int], region: BackendAPI.BookPageRegion? = nil) {
            self.pages = Array(Set(pages)).sorted()
            self.region = region
        }
    }

    struct Turn: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let question: String
        /// The PDF pages and optional rectangle used for this particular turn.
        let pages: [Int]
        let region: BackendAPI.BookPageRegion?
        let text: String
        let citations: [BackendAPI.BookCitation]
        let pagesRead: [Int]

        init(
            id: UUID = UUID(),
            question: String,
            pages: [Int],
            region: BackendAPI.BookPageRegion? = nil,
            text: String,
            citations: [BackendAPI.BookCitation],
            pagesRead: [Int]
        ) {
            self.id = id
            self.question = question
            self.pages = pages
            self.region = region
            self.text = text
            self.citations = citations
            self.pagesRead = pagesRead
        }
    }

    struct Conversation: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        var title: String
        var turns: [Turn]
        var draft: String
        let createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            title: String = "Neue Unterhaltung",
            turns: [Turn] = [],
            draft: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.turns = turns
            self.draft = draft
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    private struct SavedState: Codable, Sendable {
        var conversations: [Conversation]
        var selectedConversationID: UUID
    }

    /// Keep JSON encoding and atomic file replacement off the main actor.
    private actor PersistenceWriter {
        private var newestRevision = 0

        func save(_ state: SavedState, revision: Int, key: String) {
            guard revision >= newestRevision else { return }
            newestRevision = revision
            OfflineCache.save(state, as: key)
        }
    }

    private(set) var conversations: [Conversation]
    private(set) var selectedConversationID: UUID
    private(set) var context = Context(pages: [])
    private var pendingByConversation: [UUID: (question: String, context: Context)] = [:]
    private var errors: [UUID: String] = [:]
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var requestIDs: [UUID: UUID] = [:]

    private let persistenceEnabled: Bool
    private let storageKey: String?
    @ObservationIgnored private let persistenceWriter = PersistenceWriter()
    @ObservationIgnored private var persistenceRevision = 0

    init(bookID: String? = nil, loadPersisted: Bool = true) {
        let key = bookID.map { Self.storageKey(for: $0) }
        storageKey = key
        persistenceEnabled = loadPersisted && key != nil

        if UITestRuntime.isEnabled, UITestRuntime.scenario != .empty {
            conversations = Self.uiTestConversations
            selectedConversationID = conversations[0].id
        } else if loadPersisted,
                  let key,
                  let saved = OfflineCache.load(SavedState.self, key: key),
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

    var currentConversation: Conversation { conversations[currentIndex] }
    var turns: [Turn] { currentConversation.turns }

    var draft: String {
        get { conversations[currentIndex].draft }
        set { conversations[currentIndex].draft = newValue }
    }

    var sending: Bool { requestIDs[selectedConversationID] != nil }
    var pending: (question: String, pages: [Int])? {
        pendingByConversation[selectedConversationID].map { ($0.question, $0.context.pages) }
    }

    var errorMessage: String? { errors[selectedConversationID] }
    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var hasConversation: Bool {
        !turns.isEmpty || pending != nil || errorMessage != nil
    }

    var hasContent: Bool { hasConversation || !draft.isEmpty }

    /// Selection affects only subsequent requests; it never changes which
    /// conversation (and therefore which messages) is visible.
    func activate(_ newContext: Context) {
        context = newContext
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        cancel()
        selectedConversationID = id
        persist()
    }

    func createConversation() {
        cancel()
        if turns.isEmpty, draft.isEmpty {
            errors[selectedConversationID] = nil
            return
        }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        persist()
    }

    func rename(_ id: UUID, to proposedTitle: String) {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = index(of: id) else { return }
        conversations[index].title = String(title.prefix(80))
        touchConversation(id)
    }

    func delete(_ id: UUID) {
        if selectedConversationID == id { cancel() }
        conversations.removeAll { $0.id == id }
        requestTasks[id]?.cancel()
        requestTasks[id] = nil
        requestIDs[id] = nil
        pendingByConversation[id] = nil
        errors[id] = nil

        if conversations.isEmpty {
            let conversation = Conversation()
            conversations = [conversation]
            selectedConversationID = conversation.id
        } else if !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations[0].id
        }
        persist()
    }
}

extension BookAIStore {
    func ask(
        _ question: String,
        bookID: String,
        api: BackendAPI,
        replacing turnID: UUID? = nil,
        using contextOverride: Context? = nil
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = selectedConversationID
        let requestContext = contextOverride ?? context
        guard !trimmed.isEmpty,
              requestIDs[conversationID] == nil,
              !requestContext.pages.isEmpty,
              let conversationIndex = index(of: conversationID)
        else { return }

        errors[conversationID] = nil
        conversations[conversationIndex].draft = ""
        pendingByConversation[conversationID] = (trimmed, requestContext)
        let operationID = UUID()
        requestIDs[conversationID] = operationID

        let thread = conversations[conversationIndex].turns
        let previous: Turn? = if let turnID,
                                 let turnIndex = thread.firstIndex(where: { $0.id == turnID }) {
            turnIndex > 0 ? thread[turnIndex - 1] : nil
        } else {
            thread.last
        }
        if thread.isEmpty, turnID == nil {
            conversations[conversationIndex].title = Self.title(for: trimmed)
        }
        touchConversation(conversationID)
        startRequest(
            question: trimmed,
            previous: previous,
            turnID: turnID,
            context: requestContext,
            conversationID: conversationID,
            operationID: operationID,
            bookID: bookID,
            api: api
        )
    }

    private func startRequest(
        question: String,
        previous: Turn?,
        turnID: UUID?,
        context: Context,
        conversationID: UUID,
        operationID: UUID,
        bookID: String,
        api: BackendAPI
    ) {
        requestTasks[conversationID] = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await api.askBook(
                    id: bookID,
                    question: BookAIPrompts.formatted(
                        Self.scoped(
                            Self.grounded(question, after: previous),
                            to: context.region
                        )
                    ),
                    pages: context.pages,
                    region: context.region
                )
                if !Task.isCancelled {
                    complete(
                        answer,
                        question: question,
                        turnID: turnID,
                        context: context,
                        conversationID: conversationID,
                        operationID: operationID
                    )
                }
            } catch {
                recordFailure(
                    error,
                    question: question,
                    conversationID: conversationID,
                    operationID: operationID,
                    wasCancelled: Task.isCancelled
                )
            }
            finishRequest(conversationID: conversationID, operationID: operationID)
        }
    }

    private func complete(
        _ answer: BackendAPI.BookAnswer,
        question: String,
        turnID: UUID?,
        context: Context,
        conversationID: UUID,
        operationID: UUID
    ) {
        guard requestIDs[conversationID] == operationID, let index = index(of: conversationID) else { return }
        let completed = Turn(
            question: question,
            pages: context.pages,
            region: context.region,
            text: answer.text,
            citations: answer.citations,
            pagesRead: answer.pagesRead
        )
        if let turnID,
           let turnIndex = conversations[index].turns.firstIndex(where: { $0.id == turnID }) {
            conversations[index].turns[turnIndex] = completed
        } else {
            conversations[index].turns.append(completed)
        }
        touchConversation(conversationID)
    }

    private func recordFailure(
        _ error: Error,
        question: String,
        conversationID: UUID,
        operationID: UUID,
        wasCancelled: Bool
    ) {
        guard requestIDs[conversationID] == operationID else { return }
        if !wasCancelled { errors[conversationID] = error.localizedDescription }
        if let index = index(of: conversationID) {
            conversations[index].draft = question
        }
    }

    private func finishRequest(conversationID: UUID, operationID: UUID) {
        guard requestIDs[conversationID] == operationID else { return }
        requestTasks[conversationID] = nil
        requestIDs[conversationID] = nil
        pendingByConversation[conversationID] = nil
        persist()
    }

    func retry(_ turn: Turn, bookID: String, api: BackendAPI) {
        ask(
            turn.question,
            bookID: bookID,
            api: api,
            replacing: turn.id,
            using: Context(pages: turn.pages, region: turn.region)
        )
    }

    func cancel() {
        let conversationID = selectedConversationID
        requestTasks[conversationID]?.cancel()
        requestTasks[conversationID] = nil
        requestIDs[conversationID] = nil
        if let pending = pendingByConversation[conversationID], let index = index(of: conversationID) {
            conversations[index].draft = pending.question
        }
        pendingByConversation[conversationID] = nil
        persist()
    }

    func clear() {
        cancel()
        conversations[currentIndex].turns = []
        conversations[currentIndex].draft = ""
        conversations[currentIndex].title = "Neue Unterhaltung"
        conversations[currentIndex].updatedAt = Date()
        errors[selectedConversationID] = nil
        persist()
    }

    /// What actually goes up the wire. A follow-up gets the previous turn in
    /// front of it because the book endpoint itself is stateless.
    static func grounded(_ question: String, after previous: Turn?) -> String {
        guard let previous else { return question }
        let quoted = previous.text.count > answerContextLimit
            ? previous.text.prefix(answerContextLimit).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            : previous.text
        return """
        Zuvor gefragt: „\(previous.question)“
        Deine Antwort darauf: \(quoted)

        \(question)
        """
    }

    /// Region-aware servers use the structured rectangle sent beside the
    /// question. The textual description also supports older strict servers.
    static func scoped(_ question: String, to region: BackendAPI.BookPageRegion?) -> String {
        guard let region else { return question }
        let left = Int((region.x * 100).rounded())
        let top = Int(((1 - region.y - region.height) * 100).rounded())
        let right = Int(((region.x + region.width) * 100).rounded())
        let bottom = Int(((1 - region.y) * 100).rounded())
        return """
        Der Nutzer hat auf PDF-Seite \(region.pdfPage) einen Bereich markiert: \
        von \(left) % links / \(top) % oben bis \(right) % links / \(bottom) % oben. \
        Beziehe dich vorrangig auf diesen Ausschnitt.

        \(question)
        """
    }

    private func touchConversation(_ id: UUID) {
        guard let index = index(of: id) else { return }
        conversations[index].updatedAt = Date()
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func index(of id: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == id })
    }

    private var currentIndex: Int {
        index(of: selectedConversationID) ?? 0
    }

    private func persist() {
        guard persistenceEnabled, let storageKey else { return }
        persistenceRevision += 1
        let revision = persistenceRevision
        let snapshot = SavedState(
            conversations: conversations,
            selectedConversationID: selectedConversationID
        )
        Task { [persistenceWriter] in
            await persistenceWriter.save(snapshot, revision: revision, key: storageKey)
        }
    }

    private static func storageKey(for bookID: String) -> String {
        let encoded = Data(bookID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "book-ai-conversations-v1-\(encoded)"
    }

    private static func title(for question: String) -> String {
        let normalized = question
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let prefix = normalized.prefix(52)
        return prefix.count < normalized.count ? "\(prefix)…" : String(prefix)
    }

    /// How much of the previous answer is quoted back as context.
    private static let answerContextLimit = 1200

    private static var uiTestConversations: [Conversation] {
        let base = Date(timeIntervalSince1970: 1_775_702_400)
        let longSuffix = UITestRuntime.scenario == .longContent
            ? String(repeating: " Zusätzlicher Buchinhalt prüft Scrollen und Textumbruch.", count: 16)
            : ""
        return [
            Conversation(
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                title: "Beispiel auf Seite 2",
                turns: [
                    Turn(
                        id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                        question: "Was zeigt das Beispiel?",
                        pages: [1, 2],
                        text: "Das Beispiel zeigt einen reproduzierbaren Zusammenhang.\(longSuffix)",
                        citations: [BackendAPI.BookCitation(pdfPage: 2, note: "Definition und Beispiel")],
                        pagesRead: [1, 2, 3]
                    ),
                ],
                createdAt: base,
                updatedAt: base
            ),
            Conversation(
                id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                title: "Zweite Unterhaltung",
                turns: [],
                draft: "Welche Begriffe sind wichtig?",
                createdAt: base.addingTimeInterval(-60),
                updatedAt: base.addingTimeInterval(-60)
            ),
        ]
    }
}
