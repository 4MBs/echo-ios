@testable import MossLive
import XCTest

/// The gain stage exists to stop the noise floor being lifted in pauses, which
/// is what cost 16 dB against Voice Memos on the same iPad in the same room.
///
/// Every test here feeds **alternating speech and pauses**, because that is the
/// only input on which a speech-gated stage means anything: handed a constant
/// level it cannot tell a lecture from a ventilation duct, and correctly
/// refuses to touch either.
final class SpeechGatedGainTests: XCTestCase {
    private let sampleRate = 16000
    private let frameSamples = 320 // 20 ms

    /// Deterministic noise at a given RMS, so a failure reproduces exactly.
    private func frame(db: Double, seed: inout UInt64) -> [Int16] {
        let amplitude = pow(10, db / 20)
        return (0 ..< frameSamples).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(seed >> 11) / Double(UInt64(1) << 53) - 0.5
            return Int16(max(-32768, min(32767, (unit * 2 * amplitude * 32768).rounded())))
        }
    }

    private func decibels(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let sum = samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
        return 20 * log10(max((sum / Double(samples.count)).squareRoot(), 1e-9))
    }

    /// One second of speech, one second of room, `cycles` times over. Returns
    /// the last frame of each, in and out, which is where the stage has settled.
    private func alternate(
        _ stage: SpeechGatedGain, speechDb: Double, roomDb: Double, cycles: Int = 60
    ) -> (speechIn: [Int16], speechOut: [Int16], roomIn: [Int16], roomOut: [Int16]) {
        var seed: UInt64 = 42
        var speechIn: [Int16] = [], speechOut: [Int16] = []
        var roomIn: [Int16] = [], roomOut: [Int16] = []
        for _ in 0 ..< cycles {
            for _ in 0 ..< 50 {
                speechIn = frame(db: speechDb, seed: &seed)
                speechOut = stage.process(speechIn, sampleRate: sampleRate)
            }
            for _ in 0 ..< 50 {
                roomIn = frame(db: roomDb, seed: &seed)
                roomOut = stage.process(roomIn, sampleRate: sampleRate)
            }
        }
        return (speechIn, speechOut, roomIn, roomOut)
    }

    /// The property the whole change exists for.
    func testTheDistanceBetweenSpeechAndRoomSurvives() {
        let heard = alternate(SpeechGatedGain(), speechDb: -34, roomDb: -64)
        let before = decibels(heard.speechIn) - decibels(heard.roomIn)
        let after = decibels(heard.speechOut) - decibels(heard.roomOut)
        XCTAssertEqual(after, before, accuracy: 1.5, "levelling must not spend signal-to-noise")
    }

    /// Said the other way round: the room must not be pushed up harder than the
    /// speech was. That is precisely what iOS's AGC does.
    func testTheRoomIsNotLiftedMoreThanSpeech() {
        let heard = alternate(SpeechGatedGain(), speechDb: -34, roomDb: -64)
        let speechGain = decibels(heard.speechOut) - decibels(heard.speechIn)
        let roomGain = decibels(heard.roomOut) - decibels(heard.roomIn)
        XCTAssertLessThanOrEqual(roomGain, speechGain + 0.5, "the room was lifted harder than the voice")
    }

    /// And it has to actually do its job: quiet speech arrives at the target.
    func testSpeechIsBroughtToTheTarget() {
        let heard = alternate(SpeechGatedGain(), speechDb: -34, roomDb: -64)
        XCTAssertEqual(decibels(heard.speechOut), -20, accuracy: 2.5)
        XCTAssertGreaterThan(
            decibels(heard.speechOut) - decibels(heard.speechIn), 8, "a quiet room was left quiet"
        )
    }

    /// A lesson is not a conversation — a teacher can talk for minutes without a
    /// gap. An estimator that treats sustained speech as the room rising climbs
    /// past the speaker, shuts its own gate and freezes the gain there.
    func testAnUninterruptedMonologueDoesNotShutTheGate() {
        let stage = SpeechGatedGain()
        var seed: UInt64 = 7
        for _ in 0 ..< 50 { _ = stage.process(frame(db: -64, seed: &seed), sampleRate: sampleRate) }
        var out: [Int16] = []
        for _ in 0 ..< 6000 { // two minutes, no pause at all
            out = stage.process(frame(db: -34, seed: &seed), sampleRate: sampleRate)
        }
        XCTAssertEqual(decibels(out), -20, accuracy: 2.5, "the gain froze mid-lecture")
        XCTAssertLessThan(stage.noiseFloorDb ?? 0, -50, "the floor estimate climbed into the speech")
    }

    func testTheGainNeverExceedsItsCap() {
        var settings = SpeechGatedGain.Settings()
        settings.maxGainDb = 12
        let stage = SpeechGatedGain(settings: settings)
        _ = alternate(stage, speechDb: -50, roomDb: -80)
        XCTAssertLessThanOrEqual(stage.gainDb, 12.0001)
    }

    /// A shout at close range must bend, not turn into a square wave.
    func testLoudInputIsBentRatherThanClipped() {
        let stage = SpeechGatedGain()
        var seed: UInt64 = 3
        for _ in 0 ..< 50 { _ = stage.process(frame(db: -64, seed: &seed), sampleRate: sampleRate) }
        var clipped = 0
        for _ in 0 ..< 200 {
            for sample in stage.process(frame(db: -3, seed: &seed), sampleRate: sampleRate)
                where sample == Int16.max || sample == Int16.min {
                clipped += 1
            }
        }
        XCTAssertEqual(clipped, 0, "the limiter let \(clipped) samples hit the rail")
    }

    /// Handed one steady level and nothing else, the stage has no way to tell
    /// speech from room tone — and must therefore leave it alone rather than
    /// guess. This is the case that makes the gate worth having.
    func testAConstantLevelIsNotAmplifiedOnFaith() {
        let stage = SpeechGatedGain()
        var seed: UInt64 = 11
        var out: [Int16] = [], last: [Int16] = []
        for _ in 0 ..< 500 {
            last = frame(db: -50, seed: &seed)
            out = stage.process(last, sampleRate: sampleRate)
        }
        XCTAssertEqual(decibels(out), decibels(last), accuracy: 0.5)
    }

    func testEmptyAndDegenerateInput() {
        let stage = SpeechGatedGain()
        XCTAssertTrue(stage.process([], sampleRate: sampleRate).isEmpty)
        XCTAssertEqual(stage.process([0, 0, 0], sampleRate: 0), [0, 0, 0])
        XCTAssertEqual(stage.process([0, 0, 0], sampleRate: sampleRate).count, 3)
    }
}
