@testable import MossLive
import XCTest

final class ProtocolTests: XCTestCase {
    func testBinaryFrameLayoutIsBigEndian() {
        let frame = WireProtocol.packAudioFrame(
            seq: 0x0102_0304,
            captureTsMs: 0x0506_0708_090A_0B0C,
            payload: Data([0xAA, 0xBB])
        )
        XCTAssertEqual(frame.count, WireProtocol.binaryHeaderSize + 2)
        XCTAssertEqual([UInt8](frame.prefix(4)), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual([UInt8](frame[4 ..< 12]), [0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C])
        XCTAssertEqual([UInt8](frame.suffix(2)), [0xAA, 0xBB])
    }

    func testHelloEncodesSnakeCaseFields() throws {
        let hello = HelloMessage(token: "tok", sessionId: "abc", sampleRate: 16000, frameMs: 20)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encodeJSON(hello).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "hello")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["token"] as? String, "tok")
        XCTAssertEqual(json["session_id"] as? String, "abc")
        XCTAssertEqual(json["sample_rate"] as? Int, 16000)
        XCTAssertEqual(json["frame_ms"] as? Int, 20)
        XCTAssertEqual(json["codec"] as? String, "opus")
    }

    func testAnswerRequestEncoding() throws {
        let msg = AnswerRequestMessage(requestId: 7, pressedAtMs: 123, contextSeconds: 30)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encodeJSON(msg).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "answer_request")
        XCTAssertEqual(json["request_id"] as? Int, 7)
        XCTAssertEqual(json["pressed_at_ms"] as? Int, 123)
        XCTAssertEqual(json["context_seconds"] as? Double, 30)
    }

    func testDecodeHelloAck() throws {
        let msg = try ServerMessage.decode(
            #"{"type":"hello_ack","session_id":"s1","resumed":true,"server_time_ms":42}"#
        )
        XCTAssertEqual(
            msg,
            .helloAck(HelloAck(sessionId: "s1", resumed: true, serverTimeMs: 42))
        )
    }

    func testDecodeTranscript() throws {
        let raw = #"""
        {"type":"transcript",
         "segments":[{"t0":1.5,"t1":3.0,"speaker":"S01","text":"hello"}],
         "partial":[{"t0":3.2,"t1":4.0,"speaker":"S02","text":"wor"}],
         "committed_until":3.0}
        """#
        guard case .transcript(let update) = try ServerMessage.decode(raw) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(update.segments.count, 1)
        XCTAssertEqual(update.segments[0].speaker, "S01")
        XCTAssertEqual(update.partial[0].text, "wor")
        XCTAssertEqual(update.committedUntil, 3.0)
    }

    func testDecodeAnswer() throws {
        let raw = #"""
        {"type":"answer","request_id":3,"ok":true,"text":"Paris.","error":"",
         "transcript_used":"S01: what is the capital of france",
         "latency":{"window_ms":0.2,"gemini_ms":2400.0,"total_ms":2410.5}}
        """#
        guard case .answer(let payload) = try ServerMessage.decode(raw) else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(payload.requestId, 3)
        XCTAssertTrue(payload.ok)
        XCTAssertEqual(payload.text, "Paris.")
        XCTAssertEqual(payload.latency.totalMs, 2410.5, accuracy: 0.001)
    }

    func testDecodeAnswerPendingAndError() throws {
        XCTAssertEqual(
            try ServerMessage.decode(#"{"type":"answer_pending","request_id":9}"#),
            .answerPending(requestId: 9)
        )
        XCTAssertEqual(
            try ServerMessage.decode(#"{"type":"error","code":"bad_frame","message":"too big"}"#),
            .serverError(ServerErrorMessage(code: "bad_frame", message: "too big"))
        )
    }

    func testUnknownTypeDoesNotThrow() throws {
        XCTAssertEqual(
            try ServerMessage.decode(#"{"type":"future_thing","x":1}"#),
            .unknown(type: "future_thing")
        )
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try ServerMessage.decode("not json"))
    }
}
