@testable import MossLive
import XCTest

final class AnswerTrackerTests: XCTestCase {
    func testLifecycle() {
        var tracker = AnswerTracker()
        let id = tracker.begin()
        XCTAssertEqual(id, 1)
        XCTAssertEqual(tracker.current?.state, .pending)
        XCTAssertTrue(tracker.hasInflightRequest)

        tracker.markAcknowledged(id: id)
        XCTAssertEqual(tracker.current?.state, .waitingForAnswer)

        let isLatest = tracker.complete(id: id, ok: true, text: "Paris.", error: "", latencyMs: 1200)
        XCTAssertTrue(isLatest)
        XCTAssertEqual(tracker.current?.state, .success(text: "Paris.", latencyMs: 1200))
        XCTAssertFalse(tracker.hasInflightRequest)
    }

    func testOldAnswerNeverReplacesNewerRequest() {
        var tracker = AnswerTracker()
        let first = tracker.begin()
        let second = tracker.begin()

        // the old answer arrives late: must not be flagged as displayable
        XCTAssertFalse(tracker.complete(id: first, ok: true, text: "OLD", error: "", latencyMs: 1))
        // current record still belongs to the newer press
        XCTAssertEqual(tracker.current?.id, second)
        XCTAssertEqual(tracker.current?.state, .pending)

        XCTAssertTrue(tracker.complete(id: second, ok: true, text: "NEW", error: "", latencyMs: 2))
        XCTAssertEqual(tracker.current?.state, .success(text: "NEW", latencyMs: 2))
        // the old record kept its own result in history
        XCTAssertEqual(tracker.records.first?.state, .success(text: "OLD", latencyMs: 1))
    }

    func testStreamingDeltasAccumulate() {
        var tracker = AnswerTracker()
        let id = tracker.begin()
        tracker.markAcknowledged(id: id)
        tracker.appendDelta(id: id, text: "Pa")
        tracker.appendDelta(id: id, text: "ris")
        XCTAssertEqual(tracker.current?.state, .streaming(partial: "Paris"))
        XCTAssertTrue(tracker.hasInflightRequest)

        tracker.complete(id: id, ok: true, text: "Paris.", error: "", latencyMs: 900)
        XCTAssertEqual(tracker.current?.state, .success(text: "Paris.", latencyMs: 900))
        // late deltas after completion are ignored
        tracker.appendDelta(id: id, text: "junk")
        XCTAssertEqual(tracker.current?.state, .success(text: "Paris.", latencyMs: 900))
    }

    func testDeltaForUnknownIdIgnored() {
        var tracker = AnswerTracker()
        _ = tracker.begin()
        tracker.appendDelta(id: 999, text: "x")
        XCTAssertEqual(tracker.current?.state, .pending)
    }

    func testFailureState() {
        var tracker = AnswerTracker()
        let id = tracker.begin()
        tracker.complete(id: id, ok: false, text: "", error: "quota", latencyMs: 0)
        XCTAssertEqual(tracker.current?.state, .failure(error: "quota"))
    }

    func testFailAllInflight() {
        var tracker = AnswerTracker()
        let a = tracker.begin()
        let b = tracker.begin()
        tracker.markAcknowledged(id: b)
        tracker.complete(id: a, ok: true, text: "done", error: "", latencyMs: 1)
        tracker.failAllInflight(error: "disconnected")
        XCTAssertEqual(tracker.records[0].state, .success(text: "done", latencyMs: 1))
        XCTAssertEqual(tracker.records[1].state, .failure(error: "disconnected"))
    }

    func testUnknownIdIgnored() {
        var tracker = AnswerTracker()
        _ = tracker.begin()
        XCTAssertFalse(tracker.complete(id: 999, ok: true, text: "?", error: "", latencyMs: 0))
        XCTAssertEqual(tracker.current?.state, .pending)
    }

    func testHistoryBounded() {
        var tracker = AnswerTracker(maxHistory: 3)
        for _ in 0 ..< 10 {
            _ = tracker.begin()
        }
        XCTAssertEqual(tracker.records.count, 3)
        XCTAssertEqual(tracker.current?.id, 10)
    }
}
