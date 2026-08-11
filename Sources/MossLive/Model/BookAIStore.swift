import Foundation
import Observation

/// "Seite fragen" state for one open book. Each page, spread or marked region
/// owns its own short-lived thread, so turning the page can never make a
/// follow-up silently refer to an answer about somewhere else in the book.
///
/// It is a short thread rather than a single exchange. The endpoint is
/// stateless — `POST /library/{id}/ask` is told a question and the pages on
/// screen and nothing else — but "erklär das nochmal einfacher" is the most
/// common next thing a student says, and it cannot mean anything if the answer
/// it refers to has already been thrown off the screen. So the turns stay, and
/// a follow-up carries the turn before it up with it as context.
///
/// The thread belongs to one open book and dies with it: a book is not a
/// conversation to keep.
@MainActor
@Observable
final class BookAIStore {
    struct Context: Hashable, Sendable {
        let pages: [Int]
        let region: BackendAPI.BookPageRegion?

        init(pages: [Int], region: BackendAPI.BookPageRegion? = nil) {
            self.pages = Array(Set(pages)).sorted()
            self.region = region
        }
    }

    /// A question and what came back for it — kept together so an answer can
    /// never be read under a different question than it was given.
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        /// The PDF pages the question was asked about.
        let pages: [Int]
        let text: String
        let citations: [BackendAPI.BookCitation]
        let pagesRead: [Int]

        init(
            question: String,
            pages: [Int],
            text: String,
            citations: [BackendAPI.BookCitation],
            pagesRead: [Int]
        ) {
            self.question = question
            self.pages = pages
            self.text = text
            self.citations = citations
            self.pagesRead = pagesRead
        }
    }

    private(set) var context = Context(pages: [])
    private var threads: [Context: [Turn]] = [:]
    private var drafts: [Context: String] = [:]
    /// The question in flight. It is shown at the end of the thread under a
    /// spinner, so asking a follow-up never blanks the answer it follows up on.
    private(set) var pendingByContext: [Context: String] = [:]
    private(set) var errors: [Context: String] = [:]
    private var requestTasks: [Context: Task<Void, Never>] = [:]
    private var requestIDs: [Context: UUID] = [:]

    var turns: [Turn] { threads[context] ?? [] }
    var draft: String {
        get { drafts[context] ?? "" }
        set { drafts[context] = newValue }
    }

    var sending: Bool { requestIDs[context] != nil }
    var pending: (question: String, pages: [Int])? {
        pendingByContext[context].map { ($0, context.pages) }
    }

    var errorMessage: String? { errors[context] }
    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    /// A draft is unfinished input, not a running conversation. Keeping this
    /// distinction prevents the destructive toolbar action from appearing
    /// before there is an exchange, request or failed request to clear.
    var hasConversation: Bool {
        !turns.isEmpty || pending != nil || errorMessage != nil
    }

    /// Whether the panel has any state worth preserving when it redraws.
    var hasContent: Bool {
        hasConversation || !draft.isEmpty
    }

    func activate(_ newContext: Context) {
        context = newContext
    }

    func ask(
        _ question: String,
        bookID: String,
        api: BackendAPI,
        replacing turnID: UUID? = nil
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = context
        guard !trimmed.isEmpty, requestIDs[target] == nil, !target.pages.isEmpty else { return }
        errors[target] = nil
        drafts[target] = ""
        pendingByContext[target] = trimmed
        let operationID = UUID()
        requestIDs[target] = operationID

        let thread = threads[target] ?? []
        let previous: Turn? = if let turnID, let index = thread.firstIndex(where: { $0.id == turnID }) {
            index > 0 ? thread[index - 1] : nil
        } else {
            thread.last
        }
        requestTasks[target] = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await api.askBook(
                    id: bookID,
                    question: BookAIPrompts.formatted(
                        Self.scoped(
                            Self.grounded(trimmed, after: previous),
                            to: target.region
                        )
                    ),
                    pages: target.pages,
                    region: target.region
                )
                if !Task.isCancelled, requestIDs[target] == operationID {
                    let completed = Turn(
                        question: trimmed,
                        pages: target.pages,
                        text: answer.text,
                        citations: answer.citations,
                        pagesRead: answer.pagesRead
                    )
                    var thread = threads[target] ?? []
                    if let turnID, let index = thread.firstIndex(where: { $0.id == turnID }) {
                        thread[index] = completed
                    } else {
                        thread.append(completed)
                    }
                    threads[target] = thread
                }
            } catch {
                guard requestIDs[target] == operationID else { return }
                if Task.isCancelled {
                    drafts[target] = trimmed
                } else {
                    errors[target] = error.localizedDescription
                    drafts[target] = trimmed
                }
            }
            if requestIDs[target] == operationID {
                requestTasks[target] = nil
                requestIDs[target] = nil
                pendingByContext[target] = nil
            }
        }
    }

    func retry(_ turn: Turn, bookID: String, api: BackendAPI) {
        ask(turn.question, bookID: bookID, api: api, replacing: turn.id)
    }

    func cancel() {
        let target = context
        requestTasks[target]?.cancel()
        requestTasks[target] = nil
        requestIDs[target] = nil
        if let question = pendingByContext[target] { drafts[target] = question }
        pendingByContext[target] = nil
    }

    func clear() {
        cancel()
        threads[context] = []
        errors[context] = nil
        drafts[context] = ""
    }

    /// What actually goes up the wire. A first question travels as typed; a
    /// follow-up gets the turn before it in front of it, because the server
    /// remembers nothing between calls and "erklär das nochmal einfacher" is
    /// unanswerable without knowing what "das" was.
    ///
    /// Only the last turn, and only the front of its answer: the page itself is
    /// the context that matters, and a full second answer quoted back would
    /// crowd it out.
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
    /// question. This short textual description also gives older servers a
    /// useful fallback when they already show the full rendered page to their
    /// vision model but ignore unknown JSON fields.
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

    /// How much of the previous answer is quoted back as context.
    private static let answerContextLimit = 1200
}
