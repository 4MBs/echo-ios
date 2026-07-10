import XCTest
@testable import MossLive

final class BackoffPolicyTests: XCTestCase {
    func testCapDoublesAndSaturates() {
        var policy = BackoffPolicy(baseDelay: 0.5, maxDelay: 10)
        var caps: [Double] = []
        for _ in 0..<7 {
            caps.append(policy.currentCap)
            _ = policy.nextDelay(random: { $0.upperBound })
        }
        XCTAssertEqual(caps, [0.5, 1.0, 2.0, 4.0, 8.0, 10.0, 10.0])
    }

    func testJitterStaysInRange() {
        var policy = BackoffPolicy(baseDelay: 0.5, maxDelay: 10)
        for _ in 0..<20 {
            let cap = policy.currentCap
            let delay = policy.nextDelay()
            XCTAssertGreaterThanOrEqual(delay, 0.05)
            XCTAssertLessThanOrEqual(delay, cap)
        }
    }

    func testResetRestartsSchedule() {
        var policy = BackoffPolicy(baseDelay: 0.5, maxDelay: 10)
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        policy.reset()
        XCTAssertEqual(policy.currentCap, 0.5)
        XCTAssertEqual(policy.attempt, 0)
    }
}
