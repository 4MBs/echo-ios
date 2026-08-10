import Foundation
import Observation

/// Buch-KI's state for one open book: the questions asked about it, the answers
/// that came back, and whatever is being typed next.
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
    }

    var draft = ""
    private(set) var turns: [Turn] = []
    private(set) var sending = false
    /// The question in flight. It is shown at the end of the thread under a
    /// spinner, so asking a follow-up never blanks the answer it follows up on.
    private(set) var pending: (question: String, pages: [Int])?
    private(set) var errorMessage: String?
    /// The question of a failed attempt, so "Erneut versuchen" has something
    /// to retry.
    private(set) var lastFailed: (question: String, pages: [Int])?

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    /// Whether there is anything the panel's menu could clear.
    var hasContent: Bool {
        !turns.isEmpty || errorMessage != nil
    }

    func ask(_ question: String, pages: [Int], bookID: String, api: BackendAPI) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, !pages.isEmpty else { return }
        errorMessage = nil
        lastFailed = nil
        draft = ""
        pending = (trimmed, pages)
        sending = true
        defer {
            sending = false
            pending = nil
        }
        do {
            let answer = try await api.askBook(
                id: bookID,
                question: Self.grounded(trimmed, after: turns.last),
                pages: pages
            )
            turns.append(Turn(
                question: trimmed,
                pages: pages,
                text: answer.text,
                citations: answer.citations,
                pagesRead: answer.pagesRead
            ))
        } catch {
            errorMessage = error.localizedDescription
            lastFailed = (trimmed, pages)
        }
    }

    func clear() {
        turns = []
        errorMessage = nil
        lastFailed = nil
        draft = ""
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

    /// How much of the previous answer is quoted back as context.
    private static let answerContextLimit = 1200
}
