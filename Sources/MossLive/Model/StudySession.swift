import Foundation
import Observation

/// One study round, from the first question to the result.
///
/// It lives on `AppModel` and is written to disk after every answer, because a
/// round is the one thing in this app that is *work*: locking the iPad, taking a
/// call or being killed for memory in the middle of question seven must not
/// throw away the six answers already given. The previous screen kept all of it
/// in `@State`, so swiping back lost the round.
@MainActor
@Observable
final class StudySession {
    /// What an answer does to the schedule.
    enum Mode: String, Codable, Sendable {
        /// Counts: the server reschedules the card.
        case review
        /// Does not count, and says so.
        case practice
        /// A mock paper. Counts as well — the server reschedules from it — and
        /// the result screen says so rather than leaving it to be discovered.
        case exam

        var reportsResults: Bool { self != .practice }
        var apiName: String { rawValue }
    }

    struct Answer: Codable, Equatable, Sendable {
        let cardId: String
        let correct: Bool
        /// 0…3, the scale `POST /learn/review` already takes.
        let rating: Int
    }

    let mode: Mode
    /// What the round is called, for VoiceOver and for the resume line on Heute.
    let title: String
    private(set) var cards: [BackendAPI.LearnCard]
    private(set) var index: Int
    private(set) var answers: [Answer]
    private(set) var updatedAt: Date

    /// How long a round may sit untouched and still be worth resuming. Past
    /// half an hour it is a new evening, not the same round.
    static let resumeWindow: TimeInterval = 30 * 60

    init(mode: Mode, title: String, cards: [BackendAPI.LearnCard]) {
        self.mode = mode
        self.title = title
        self.cards = cards
        index = 0
        answers = []
        updatedAt = Date()
        persist()
    }

    private init(_ stored: Stored) {
        mode = stored.mode
        title = stored.title
        cards = stored.cards
        index = stored.index
        answers = stored.answers
        updatedAt = stored.updatedAt
    }

    // MARK: - Where the round is

    var current: BackendAPI.LearnCard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var isFinished: Bool { index >= cards.count }

    /// "7 von 24" — one-based, and never past the end.
    var position: Int { min(index + 1, cards.count) }

    var total: Int { cards.count }

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(answers.count) / Double(total)
    }

    var correctCount: Int { answers.filter(\.correct).count }

    /// The cards that were missed, in the order they were asked.
    var missedCards: [BackendAPI.LearnCard] {
        let missed = Set(answers.filter { !$0.correct }.map(\.cardId))
        return cards.filter { missed.contains($0.id) }
    }

    /// Whether picking this up again would save the student anything.
    var isResumable: Bool { !isFinished && !answers.isEmpty }

    // MARK: - Answering

    /// Record the answer to the current card. Idempotent: a double tap on an
    /// option cannot report the same card twice.
    @discardableResult
    func record(correct: Bool, rating: Int) -> Bool {
        guard let card = current else { return false }
        guard !answers.contains(where: { $0.cardId == card.id }) else { return false }
        answers.append(Answer(cardId: card.id, correct: correct, rating: rating))
        touch()
        return true
    }

    func advance() {
        index += 1
        touch()
    }

    private func touch() {
        updatedAt = Date()
        persist()
    }

    // MARK: - Storage

    private struct Stored: Codable {
        let mode: Mode
        let title: String
        let cards: [BackendAPI.LearnCard]
        let index: Int
        let answers: [Answer]
        let updatedAt: Date
    }

    private func persist() {
        guard !isFinished else {
            discard()
            return
        }
        OfflineCache.save(
            Stored(mode: mode, title: title, cards: cards, index: index, answers: answers, updatedAt: updatedAt),
            as: OfflineCache.Key.studySession
        )
    }

    func discard() {
        OfflineCache.remove(key: OfflineCache.Key.studySession)
    }

    /// The round that was running when the app went away, if it was recent
    /// enough to still be the same sitting.
    static func restore(now: Date = Date()) -> StudySession? {
        guard let stored = OfflineCache.load(Stored.self, key: OfflineCache.Key.studySession) else { return nil }
        guard now.timeIntervalSince(stored.updatedAt) < resumeWindow,
              stored.index < stored.cards.count,
              !stored.answers.isEmpty
        else {
            OfflineCache.remove(key: OfflineCache.Key.studySession)
            return nil
        }
        return StudySession(stored)
    }
}
