import AVFoundation
@testable import MossLive
import XCTest

/// The microphone hand-off that keeps chat dictation from ending a lesson
/// recording: capture publishes, dictation listens, nobody takes.
final class SharedMicrophoneTests: XCTestCase {
    private let microphone = SharedMicrophone.shared

    private static func buffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        return buffer
    }

    override func tearDown() {
        microphone.end()
        super.tearDown()
    }

    func testNotCapturingUntilARecordingClaimsTheMicrophone() throws {
        XCTAssertFalse(microphone.isCapturing)
        XCTAssertNil(microphone.format)

        let format = try Self.buffer().format
        microphone.begin(format: format)
        XCTAssertTrue(microphone.isCapturing)
        XCTAssertEqual(microphone.format?.sampleRate, 48000)

        microphone.end()
        XCTAssertFalse(microphone.isCapturing)
    }

    func testListenersReceivePublishedBuffersUntilRemoved() throws {
        let received = Counter()
        let listener = microphone.addListener { _ in received.increment() }

        try microphone.publish(Self.buffer())
        try microphone.publish(Self.buffer())
        XCTAssertEqual(received.value, 2)

        microphone.removeListener(listener)
        try microphone.publish(Self.buffer())
        XCTAssertEqual(received.value, 2, "a removed listener must not keep reading the microphone")
    }

    func testSeveralListenersEachSeeEveryBuffer() throws {
        let first = Counter()
        let second = Counter()
        let a = microphone.addListener { _ in first.increment() }
        let b = microphone.addListener { _ in second.increment() }
        defer {
            microphone.removeListener(a)
            microphone.removeListener(b)
        }

        try microphone.publish(Self.buffer())

        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
    }
}

/// Buffers are published from the audio thread, so the count is locked.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
