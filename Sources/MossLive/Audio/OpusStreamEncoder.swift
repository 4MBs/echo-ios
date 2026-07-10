import Foundation
import OpusShim

enum AudioPipelineConstants {
    /// Matches the MOSS/Whisper feature extractor — the server never resamples.
    static let sampleRate = 16000
    static let frameMs = 20
    static var frameSamples: Int { sampleRate * frameMs / 1000 }
}

/// Streaming Opus encoder: feed arbitrary-length int16 mono 16 kHz PCM, get
/// back one packet per 20 ms frame, each tagged with a monotonically
/// increasing sequence number.
///
/// The sequence number advances for every *encoded* frame, including frames
/// dropped while offline — the server turns the resulting gaps into silence,
/// keeping the session timeline aligned with wall time (that is what makes
/// "the last 30 seconds" timestamp-accurate across disconnects).
final class OpusStreamEncoder {
    struct Packet {
        let seq: UInt32
        let captureTsMs: UInt64
        let payload: Data
    }

    enum EncoderError: Error, CustomStringConvertible {
        case createFailed(Int32)
        case configureFailed(Int32)
        case encodeFailed(Int32)

        var description: String {
            switch self {
            case .createFailed(let code): return "opus encoder create failed: \(opusMessage(code))"
            case .configureFailed(let code): return "opus encoder configure failed: \(opusMessage(code))"
            case .encodeFailed(let code): return "opus encode failed: \(opusMessage(code))"
            }
        }
    }

    private var handle: UnsafeMutableRawPointer
    private var pending: [Int16] = []
    private var seq: UInt32 = 0
    private var outBuffer = [UInt8](repeating: 0, count: 1500)

    init(bitrate: Int = 24000, complexity: Int = 5, expectedLossPercent: Int = 10) throws {
        var error: Int32 = 0
        guard let handle = moss_opus_encoder_create(
            Int32(AudioPipelineConstants.sampleRate), 1, &error
        ) else {
            throw EncoderError.createFailed(error)
        }
        self.handle = handle
        let rc = moss_opus_encoder_configure(
            handle, Int32(bitrate), Int32(complexity), 1, Int32(expectedLossPercent)
        )
        guard rc == 0 else {
            moss_opus_encoder_destroy(handle)
            throw EncoderError.configureFailed(rc)
        }
        pending.reserveCapacity(AudioPipelineConstants.frameSamples * 4)
    }

    deinit {
        moss_opus_encoder_destroy(handle)
    }

    /// Restart packet numbering (new server session — not a resume).
    func resetSequence() {
        seq = 0
    }

    var framesEncoded: UInt32 { seq }

    /// Append PCM and encode every complete 20 ms frame.
    func feed(_ samples: [Int16], captureTsMs: UInt64) throws -> [Packet] {
        pending.append(contentsOf: samples)
        let frameSamples = AudioPipelineConstants.frameSamples
        var packets: [Packet] = []
        var offset = 0
        while pending.count - offset >= frameSamples {
            let frame = Array(pending[offset ..< offset + frameSamples])
            offset += frameSamples
            let written = frame.withUnsafeBufferPointer { buf in
                moss_opus_encode(handle, buf.baseAddress, Int32(frameSamples),
                                 &outBuffer, Int32(outBuffer.count))
            }
            guard written > 0 else { throw EncoderError.encodeFailed(written) }
            packets.append(
                Packet(seq: seq, captureTsMs: captureTsMs, payload: Data(outBuffer[0 ..< Int(written)]))
            )
            seq &+= 1
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
        return packets
    }
}

private func opusMessage(_ code: Int32) -> String {
    guard let cString = moss_opus_strerror(code) else { return "error \(code)" }
    return String(cString: cString)
}
