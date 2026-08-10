import Foundation

/// What is worth doing today: the cards of one round, and the two or three lines
/// that say what is in it.
///
/// The server builds this from the schedule and the exam dates
/// (`GET /learn/plan?minutes=`). It is rebuilt here from the stored deck when
/// there is no server — a round of due cards is arithmetic over dates, and there
/// is no reason for a train journey to be a blank screen.
struct StudyPlan: Equatable {
    /// One subject's share of the round.
    struct Block: Identifiable, Equatable {
        let subject: String
        let cardCount: Int
        let estimatedMinutes: Int
        /// Why this is in today's round, in one short phrase.
        let reason: String

        var id: String { "\(subject)|\(reason)" }
    }

    var cards: [BackendAPI.LearnCard]
    var blocks: [Block]
    var estimatedMinutes: Int
    /// Whether this was worked out on the iPad rather than by the server.
    var isLocal: Bool

    var isEmpty: Bool { cards.isEmpty }

    /// The subjects of the round, in the order they will be asked.
    var subjects: [String] {
        var seen = Set<String>()
        return cards.compactMap { card in
            let name = card.subject ?? otherSubjectName
            return seen.insert(name).inserted ? name : nil
        }
    }

    static let empty = StudyPlan(cards: [], blocks: [], estimatedMinutes: 0, isLocal: true)

    /// How long a card takes to answer. Forty-five seconds is the figure the
    /// server plans with, so both sides of the app estimate the same round the
    /// same way.
    static let secondsPerCard: Double = 45

    static func minutes(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(1, Int((Double(count) * secondsPerCard / 60).rounded()))
    }

    /// The server's plan, minus anything already answered on this iPad and still
    /// waiting in the queue.
    static func server(
        _ plan: BackendAPI.LearnDailyPlan,
        answered: Set<String>
    ) -> StudyPlan {
        let remaining = interleaved(plan.cards.filter { !answered.contains($0.id) })
        return StudyPlan(
            cards: remaining,
            blocks: plan.blocks.map {
                Block(
                    subject: $0.subject,
                    cardCount: $0.cardCount,
                    estimatedMinutes: $0.estimatedMinutes,
                    reason: $0.reason
                )
            },
            estimatedMinutes: remaining.count == plan.cards.count
                ? plan.estimatedMinutes
                : minutes(for: remaining.count),
            isLocal: false
        )
    }

    /// The same round, worked out from the stored deck.
    ///
    /// Everything due today, cut to the daily goal, subjects interleaved so a
    /// round is not twenty minutes of one subject.
    static func local(
        cards: [BackendAPI.LearnCard],
        answered: Set<String>,
        minutes goal: Int,
        exams: [BackendAPI.LearnExam],
        today: String = LearnDay.today
    ) -> StudyPlan {
        let due = cards.filter { isCardDue($0, today: today, answered: answered) }
        let budget = max(1, Int(Double(goal) * 60 / secondsPerCard))
        let chosen = Array(interleaved(due).prefix(budget))
        return StudyPlan(
            cards: chosen,
            blocks: blocks(for: chosen, exams: exams),
            estimatedMinutes: minutes(for: chosen.count),
            isLocal: true
        )
    }

    /// One block per subject, in the order the round reaches them.
    private static func blocks(
        for cards: [BackendAPI.LearnCard],
        exams: [BackendAPI.LearnExam]
    ) -> [Block] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var sessions: [String: Set<String>] = [:]
        for card in cards {
            let name = card.subject ?? otherSubjectName
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
            sessions[name, default: []].insert(card.sessionId)
        }
        return order.map { subject in
            let count = counts[subject] ?? 0
            return Block(
                subject: subject,
                cardCount: count,
                estimatedMinutes: minutes(for: count),
                reason: reason(subject: subject, sessions: sessions[subject] ?? [], exams: exams)
            )
        }
    }

    /// Why a subject is in the round. An upcoming exam that covers these
    /// lessons is the only reason a student cares about; everything else is a
    /// repetition falling due.
    private static func reason(
        subject: String,
        sessions: Set<String>,
        exams: [BackendAPI.LearnExam]
    ) -> String {
        let match = exams
            .filter { $0.subject == subject && $0.daysRemaining >= 0 }
            .filter { !sessions.isDisjoint(with: Set($0.sessionIds)) }
            .min { $0.examDate < $1.examDate }
        guard let match, let date = LearnDay.date(match.examDate) else {
            return "Wiederholung fällig"
        }
        if match.daysRemaining <= 0 { return "Arbeit heute" }
        if match.daysRemaining <= 7 { return "Arbeit am \(LearnDay.weekday(date))" }
        return "Arbeit am \(LearnDay.short(date))"
    }

    /// Round-robin over the subjects, so a round alternates instead of running
    /// through one subject and then the next.
    static func interleaved(_ input: [BackendAPI.LearnCard]) -> [BackendAPI.LearnCard] {
        var groups: [String: [BackendAPI.LearnCard]] = [:]
        var order: [String] = []
        for card in input {
            let key = card.subject ?? otherSubjectName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(card)
        }
        var output: [BackendAPI.LearnCard] = []
        output.reserveCapacity(input.count)
        while output.count < input.count {
            for key in order {
                guard var group = groups[key], !group.isEmpty else { continue }
                output.append(group.removeFirst())
                groups[key] = group
            }
        }
        return output
    }
}
