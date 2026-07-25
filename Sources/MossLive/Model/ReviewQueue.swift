import Foundation
import Observation
import os

/// Answers given while the server was out of reach.
///
/// The Leitner schedule lives on the server, so a card answered offline cannot
/// be rescheduled there and then. Losing the answer is the wrong trade — the
/// work of answering is the part that matters — so it is written down and sent
/// the next time the server picks up. Until then the card counts as answered
/// here, which keeps it from being asked again in the same afternoon.
@MainActor
@Observable
final class ReviewQueue {
    struct Entry: Codable, Equatable, Sendable {
        let cardId: String
        let correct: Bool
        let answeredAt: Date
    }

    private(set) var pending: [Entry] = []

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "reviews")
    private static let key = "pending-reviews"

    init() {
        pending = OfflineCache.load([Entry].self, key: Self.key) ?? []
    }

    /// Cards already answered but not yet reported, so they are not offered again.
    var answeredIDs: Set<String> { Set(pending.map(\.cardId)) }

    /// Send the result, or keep it for later if that fails.
    func record(cardId: String, correct: Bool, api: BackendAPI) async {
        do {
            try await api.reviewCard(id: cardId, correct: correct)
        } catch {
            pending.append(Entry(cardId: cardId, correct: correct, answeredAt: Date()))
            persist()
            log.info("queued review for \(cardId, privacy: .public); \(self.pending.count) waiting")
        }
    }

    /// Hand the backlog over, oldest first. Stops at the first failure so the
    /// order the cards were answered in survives, and so a server that is still
    /// unreachable costs one request rather than all of them.
    func flush(api: BackendAPI) async {
        guard !pending.isEmpty else { return }
        let ordered = pending.sorted { $0.answeredAt < $1.answeredAt }
        var sent = 0
        for entry in ordered {
            do {
                try await api.reviewCard(id: entry.cardId, correct: entry.correct)
                sent += 1
            } catch {
                break
            }
        }
        guard sent > 0 else { return }
        pending = Array(ordered.dropFirst(sent))
        persist()
        log.info("sent \(sent) queued reviews; \(self.pending.count) left")
    }

    private func persist() {
        OfflineCache.save(pending, as: Self.key)
    }
}
