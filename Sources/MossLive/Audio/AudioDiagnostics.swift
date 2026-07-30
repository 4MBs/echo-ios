import AVFoundation
import Darwin
import Foundation

/// A low-frequency snapshot for the UI. The audio queue may update this often;
/// AppModel only publishes the newest value on the main actor.
struct AudioDiagnosticsSnapshot: Equatable, Sendable {
    var level: Float = 0
    var rmsDBFS: Double = -120
    var peakDBFS: Double = -120
    var noiseFloorDBFS: Double = -120
    var clippedSamplePercent: Double = 0
    var hardwareSampleRate: Double = 0
    var hardwareChannels: Int = 0
    var route = "Kein Eingang"
    var voiceProcessing = false
    var automaticGainControl = false
    var capturedSeconds: Double = 0
    var lostBuffers = 0
    var interruptions = 0
    var routeChanges = 0
}

struct AudioDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case started
        case stopped
        case routeChanged
        case interruptionBegan
        case interruptionEnded
        case mediaServicesReset
        case lostAudio
        case recovered
        case transport
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let message: String
    let gapSeconds: Double?

    init(kind: Kind, message: String, gapSeconds: Double? = nil, date: Date = .now) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.message = message
        self.gapSeconds = gapSeconds
    }
}

/// Deterministic signal measurements shared by production and regression tests.
/// Noise floor is the 20th percentile of the recent RMS history, which tracks
/// room noise without jumping up to the teacher's voice on every syllable.
struct AudioSignalAnalyzer {
    private(set) var recentRMSDBFS: [Double] = []
    private(set) var totalSamples: Int64 = 0
    private(set) var clippedSamples: Int64 = 0

    mutating func consume(_ samples: [Int16]) -> SignalMeasurement {
        guard !samples.isEmpty else {
            return SignalMeasurement(
                rmsDBFS: -120,
                peakDBFS: -120,
                noiseFloorDBFS: noiseFloor,
                clippedSamplePercent: clippingPercent,
                level: 0
            )
        }

        var sum: Double = 0
        var peak = 0
        var clipped = 0
        for sample in samples {
            let magnitude = abs(Int(sample))
            peak = max(peak, magnitude)
            if magnitude >= 32440 { clipped += 1 } // approximately -0.09 dBFS
            let value = Double(sample) / 32768
            sum += value * value
        }

        totalSamples += Int64(samples.count)
        clippedSamples += Int64(clipped)
        let rms = (sum / Double(samples.count)).squareRoot()
        let rmsDBFS = Self.decibels(rms)
        let peakDBFS = Self.decibels(Double(peak) / 32768)
        recentRMSDBFS.append(rmsDBFS)
        if recentRMSDBFS.count > 240 {
            recentRMSDBFS.removeFirst(recentRMSDBFS.count - 240)
        }

        return SignalMeasurement(
            rmsDBFS: rmsDBFS,
            peakDBFS: peakDBFS,
            noiseFloorDBFS: noiseFloor,
            clippedSamplePercent: clippingPercent,
            level: Float(min(max((rmsDBFS + 50) / 42, 0), 1))
        )
    }

    private var noiseFloor: Double {
        guard !recentRMSDBFS.isEmpty else { return -120 }
        let sorted = recentRMSDBFS.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.2))
        return sorted[index]
    }

    private var clippingPercent: Double {
        guard totalSamples > 0 else { return 0 }
        return Double(clippedSamples) / Double(totalSamples) * 100
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-6))
    }
}

struct SignalMeasurement: Equatable, Sendable {
    let rmsDBFS: Double
    let peakDBFS: Double
    let noiseFloorDBFS: Double
    let clippedSamplePercent: Double
    let level: Float
}

extension AVAudioPCMBuffer {
    /// Audio-engine tap buffers are owned by AVAudioEngine and may be reused as
    /// soon as the callback returns. Any asynchronous consumer must own a copy.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in source.indices {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { continue }
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }
}
