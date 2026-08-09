import Foundation
import Observation

/// Buch-KI's state for one open book: the question being typed, the request in
/// flight, and the answer that came back.
///
/// One question, one answer: the server is asked about the page on screen and
/// nothing else, so keeping a chat log here would suggest a shared thread that
/// does not exist. What the panel shows is always the last exchange.
@MainActor
@Observable
final class BookAIStore {
    /// A question and what came back for it — kept together so the answer can
    /// never be read under a different question than it was given.
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        /// The PDF pages the question was asked about.
        let pages: [Int]
        let text: String
        let citations: [BackendAPI.BookCitation]
        let pagesRead: [Int]
    }

    var draft = ""
    private(set) var sending = false
    private(set) var exchange: Exchange?
    private(set) var errorMessage: String?
    /// The question of a failed attempt, so "Erneut versuchen" has something
    /// to retry.
    private(set) var lastFailed: (question: String, pages: [Int])?
    /// Invalidates a response when the student clears the panel while its
    /// request is still running. Without this, "Antwort leeren" can appear to
    /// work and then the cleared answer comes back when the request finishes.
    private var requestRevision = 0

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    func ask(_ question: String, pages: [Int], bookID: String, api: BackendAPI) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, !pages.isEmpty else { return }
        requestRevision += 1
        let revision = requestRevision
        errorMessage = nil
        lastFailed = nil
        exchange = nil
        draft = ""
        sending = true
        defer {
            if requestRevision == revision { sending = false }
        }
        do {
            let answer = try await api.askBook(id: bookID, question: trimmed, pages: pages)
            guard requestRevision == revision else { return }
            exchange = Exchange(
                question: trimmed,
                pages: pages,
                text: answer.text,
                citations: answer.citations,
                pagesRead: answer.pagesRead
            )
        } catch {
            guard requestRevision == revision,
                  !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled
            else { return }
            errorMessage = error.localizedDescription
            lastFailed = (trimmed, pages)
        }
    }

    func clear() {
        requestRevision += 1
        sending = false
        exchange = nil
        errorMessage = nil
        lastFailed = nil
        draft = ""
    }
}
