import Foundation

/// Tracks answer-button requests so that concurrent presses behave correctly:
/// every request has an id, a timestamp and a lifecycle state, and an answer
/// for an *older* request can never overwrite a newer one on screen.
/// Pure logic (no networking) so it is fully unit-testable.
struct AnswerTracker: Sendable {
    enum State: Equatable, Sendable {
        case pending
        case waitingForAnswer // server acknowledged, Gemini call running
        case success(text: String, latencyMs: Double)
        case failure(error: String)
    }

    struct Record: Identifiable, Equatable, Sendable {
        let id: Int
        let pressedAt: Date
        var state: State
    }

    private(set) var records: [Record] = []
    private(set) var nextRequestId: Int = 1
    private let maxHistory: Int

    init(maxHistory: Int = 20) {
        self.maxHistory = maxHistory
    }

    var latestRequestId: Int { nextRequestId - 1 }

    /// The record the UI should display: always the most recent press.
    var current: Record? { records.last }

    var hasInflightRequest: Bool {
        records.contains { $0.state == .pending || $0.state == .waitingForAnswer }
    }

    mutating func begin(at date: Date = Date()) -> Int {
        let id = nextRequestId
        nextRequestId += 1
        records.append(Record(id: id, pressedAt: date, state: .pending))
        if records.count > maxHistory {
            records.removeFirst(records.count - maxHistory)
        }
        return id
    }

    mutating func markAcknowledged(id: Int) {
        guard let idx = records.lastIndex(where: { $0.id == id }),
              records[idx].state == .pending
        else { return }
        records[idx].state = .waitingForAnswer
    }

    /// Applies a finished answer. Returns true iff this answer belongs to the
    /// most recent request (i.e. the main answer view should show it).
    @discardableResult
    mutating func complete(id: Int, ok: Bool, text: String, error: String, latencyMs: Double) -> Bool {
        guard let idx = records.lastIndex(where: { $0.id == id }) else { return false }
        records[idx].state = ok
            ? .success(text: text, latencyMs: latencyMs)
            : .failure(error: error)
        return id == latestRequestId
    }

    /// Fails every request still in flight (connection lost, session ended...).
    mutating func failAllInflight(error: String) {
        for idx in records.indices
        where records[idx].state == .pending || records[idx].state == .waitingForAnswer {
            records[idx].state = .failure(error: error)
        }
    }

    mutating func reset() {
        records.removeAll()
    }
}
