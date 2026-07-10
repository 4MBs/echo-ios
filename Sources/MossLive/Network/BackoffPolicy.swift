import Foundation

/// Exponential backoff with full jitter for WebSocket reconnects.
/// Pure value type so the schedule is unit-testable.
struct BackoffPolicy: Sendable {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    private(set) var attempt: Int = 0

    init(baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 10.0) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Upper bound of the next delay (before jitter).
    var currentCap: TimeInterval {
        min(maxDelay, baseDelay * pow(2.0, Double(attempt)))
    }

    /// Returns the next delay (full jitter in [0.05, cap]) and advances.
    mutating func nextDelay(random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        let cap = currentCap
        attempt += 1
        return random(0.05 ... max(0.05, cap))
    }

    mutating func reset() {
        attempt = 0
    }
}
