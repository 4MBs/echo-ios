import Foundation

struct LearnReviewSession: Sendable {
    private(set) var cards: [BackendAPI.LearnCard]
    private(set) var currentIndex = 0

    init(cards: [BackendAPI.LearnCard]) {
        self.cards = cards
    }

    var currentCard: BackendAPI.LearnCard? {
        cards.indices.contains(currentIndex) ? cards[currentIndex] : nil
    }

    var completedCount: Int { min(currentIndex, cards.count) }
    var isComplete: Bool { currentIndex >= cards.count }
    var progress: Double {
        guard !cards.isEmpty else { return 1 }
        return Double(completedCount) / Double(cards.count)
    }

    mutating func advance() {
        currentIndex = min(currentIndex + 1, cards.count)
    }
}
