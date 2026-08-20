import AVFoundation
@testable import MossLive
import XCTest

/// The audio-session errors that decide whether a lesson recording can come
/// back on its own.
///
/// `localizedDescription` renders all of them as the same unhelpful sentence,
/// so the OSStatus is what a diagnostic has to carry. These three are the ones
/// that separate "iOS refused, wait for the foreground" from a real fault.
final class AudioSessionErrorTests: XCTestCase {
    private func sessionError(_ code: Int) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: code)
    }

    func testAudioSessionRefusalsRemainReadableInDiagnostics() {
        XCTAssertEqual(
            AudioCaptureEngine.describe(sessionError(561_145_187)),
            "cannotStartRecording 561145187",
            "'!rec' is iOS refusing to start a mixable recording from the background"
        )
        XCTAssertEqual(
            AudioCaptureEngine.describe(sessionError(560_557_684)),
            "cannotInterruptOthers 560557684"
        )
        XCTAssertEqual(
            AudioCaptureEngine.describe(sessionError(561_017_449)),
            "insufficientPriority 561017449"
        )
    }

    func testTheCodesMatchAVFoundationsOwnConstants() {
        // Guards against a transposed digit in the numbers above.
        XCTAssertEqual(AVAudioSession.ErrorCode.cannotStartRecording.rawValue, 561_145_187)
        XCTAssertEqual(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue, 560_557_684)
        XCTAssertEqual(AVAudioSession.ErrorCode.insufficientPriority.rawValue, 561_017_449)
    }

    func testAnUnknownErrorStillSaysWhereItCameFromAndWhatItWas() {
        let described = AudioCaptureEngine.describe(sessionError(-42))
        XCTAssertTrue(described.contains("-42"), "the code is the half worth keeping: \(described)")
        XCTAssertTrue(described.contains(NSOSStatusErrorDomain))
    }

    func testCaptureSessionMatchesTheVoiceProcessingInputGraph() {
        let options = AudioCaptureEngine.captureSessionOptions

        // Echo does not play anything while recording, so it must not duck or
        // mix unrelated apps. Recovery after a real interruption is handled by
        // rebuilding the already-running input graph, not by changing category.
        XCTAssertFalse(options.contains(.duckOthers))
        XCTAssertFalse(options.contains(.mixWithOthers))

        XCTAssertEqual(AudioCaptureEngine.captureSessionMode, .voiceChat)
        XCTAssertTrue(options.contains(.overrideMutedMicrophoneInterruption))
        XCTAssertTrue(options.contains(.allowBluetoothHFP))
    }
}
