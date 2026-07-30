import Foundation

/// The gain stage that replaces the one iOS was doing.
///
/// **Why this exists.** Capture ran in `mode: .default`, which leaves Apple's
/// input processing — most of all its automatic gain control — switched on. That
/// AGC has no idea whether it is listening to a teacher or to an empty room, so
/// in every pause it winds the gain up until the room itself is at a usable
/// level, and winds it back down when somebody speaks. The recording stays
/// loud, and the noise floor rides up and down underneath it.
///
/// Measured against Apple's own Voice Memos on the same iPad in the same room:
/// Voice Memos reached 40 dB between speech and the floor, this app reached 24.
/// The whole server chain — resampling, Opus at 24 kbps, loudness normalisation,
/// AAC — accounts for 0.3 dB of that. The other 16 dB were lost here.
///
/// **What it does instead.** It estimates where the room sits, and only moves
/// the gain while the signal is clearly above that. Silence is therefore
/// amplified by exactly whatever gain the last speech needed, and never by more:
/// the ratio between voice and room is preserved rather than compressed. A
/// linear gain cannot invent signal-to-noise, but it cannot destroy it either,
/// which is the entire point.
///
/// **What it is not.** It never gates, mutes or drops audio — the samples always
/// flow, only their scaling changes. The Silero VAD gate that was tried on the
/// server and reverted decided whether audio was *transcribed at all*; getting
/// that wrong cost whole sentences. Getting this wrong costs a few decibels of
/// level, and the transcript still sees every sample.
final class SpeechGatedGain {
    struct Settings {
        /// Where speech should end up. Below the limiter's knee with room to
        /// spare, because a lesson has shouting in it as well as talking.
        var targetDb: Double = -20
        /// How far the gain may go. The old capture comment put `.measurement`
        /// about 30 dB below where `.default` landed; the research put the
        /// missing amount at 16–18 dB. The cap sits between the two and is
        /// settable, because the right value depends on the room.
        var maxGainDb: Double = 24
        var minGainDb: Double = 0
        /// Slow up, quick down. Winding the gain up slowly is what stops it
        /// chasing a cough; coming down quickly is what stops the next loud
        /// passage clipping.
        var riseDbPerSecond: Double = 3
        var fallDbPerSecond: Double = 12
        /// How far above the estimated room level a frame has to be before it
        /// counts as somebody speaking.
        var speechMarginDb: Double = 12
        /// How fast the room estimate is allowed to climb. Slow, so that a
        /// long sentence cannot convince it the room got louder.
        var floorRiseDbPerSecond: Double = 1.5
        /// …and how quickly it follows the signal down, as a share of the gap
        /// per frame. Fast, so a quiet moment is recognised as one.
        var floorFallFactor: Double = 0.35
        /// Where the soft knee starts, as a sample magnitude. Above it the
        /// curve bends instead of clipping.
        var limiterKnee: Double = 0.7
    }

    private(set) var gainDb: Double
    /// The running estimate of the room, in dBFS. `nil` until the first frame.
    private(set) var noiseFloorDb: Double?
    /// Where the previous frame's ramp ended, so consecutive frames join up
    /// without a step — a gain that jumps between frames is audible as a click.
    private var appliedGainDb: Double

    private let settings: Settings

    init(settings: Settings = Settings()) {
        self.settings = settings
        gainDb = settings.minGainDb
        appliedGainDb = settings.minGainDb
    }

    /// One frame in, one frame out. Length and sample rate are the caller's;
    /// nothing is buffered, so this is safe to call from the audio queue.
    func process(_ samples: [Int16], sampleRate: Int) -> [Int16] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }
        let seconds = Double(samples.count) / Double(sampleRate)
        let level = Self.decibels(Self.rms(samples))

        // Measured against the floor as it stood *before* this frame, so a loud
        // frame cannot raise the bar it is being judged against.
        let floor = noiseFloorDb ?? level
        let speaking = level > floor + settings.speechMarginDb
        noiseFloorDb = updatedFloor(from: floor, level: level, speaking: speaking, seconds: seconds)

        // The gate. Note what happens when it is shut: nothing. The gain is not
        // reset, not decayed, not zeroed — it is simply left where speech put
        // it, which is what keeps the room at its true level.
        if speaking {
            let wanted = min(max(settings.targetDb - level, settings.minGainDb), settings.maxGainDb)
            let limit = (wanted > gainDb ? settings.riseDbPerSecond : settings.fallDbPerSecond) * seconds
            gainDb += max(-limit, min(limit, wanted - gainDb))
        }
        return scaled(samples, from: appliedGainDb, to: gainDb)
    }

    /// The room estimate: it follows the signal down quickly, and climbs back
    /// only while nobody is speaking.
    ///
    /// That last clause is the whole trick. Letting it climb unconditionally
    /// reads a long uninterrupted explanation as the room getting louder — at
    /// 1.5 dB/s a two-minute monologue would lift the estimate straight past the
    /// speaker, shut the gate behind itself and freeze the gain wherever it
    /// happened to be. Holding it while speech is present means the estimate
    /// only ever learns from the gaps, which is where the room actually is.
    private func updatedFloor(from current: Double, level: Double, speaking: Bool, seconds: Double) -> Double {
        if level < current {
            return current + (level - current) * settings.floorFallFactor
        }
        guard !speaking else { return current }
        return min(level, current + settings.floorRiseDbPerSecond * seconds)
    }

    /// Apply the gain, ramping across the frame, and bend anything that would
    /// otherwise clip.
    private func scaled(_ samples: [Int16], from startDb: Double, to endDb: Double) -> [Int16] {
        defer { appliedGainDb = endDb }
        let count = samples.count
        let step = count > 1 ? (endDb - startDb) / Double(count - 1) : 0
        var out = [Int16](repeating: 0, count: count)
        for index in 0 ..< count {
            let factor = pow(10, (startDb + step * Double(index)) / 20)
            out[index] = Self.clamp(limited(Double(samples[index]) / 32768 * factor))
        }
        return out
    }

    /// A soft knee rather than a wall. Past the knee the curve compresses what
    /// is left of the range instead of flattening it, so a shout arrives loud
    /// and intact rather than as a square wave.
    private func limited(_ value: Double) -> Double {
        let knee = settings.limiterKnee
        let magnitude = abs(value)
        guard magnitude > knee else { return value }
        let headroom = 1 - knee
        let bent = knee + headroom * tanh((magnitude - knee) / headroom)
        return value < 0 ? -bent : bent
    }

    private static func clamp(_ value: Double) -> Int16 {
        Int16(max(-32768, min(32767, (value * 32768).rounded())))
    }

    private static func rms(_ samples: [Int16]) -> Double {
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-9))
    }
}
