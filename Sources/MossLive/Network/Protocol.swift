import Foundation

/// Wire protocol v1 — Swift mirror of the backend's `src/mosslive/protocol.py`
/// (see docs/PROTOCOL.md in the moss-live-fedora-backend repository).
///
/// One WebSocket carries binary audio frames up and JSON text messages both ways.
enum WireProtocol {
    static let version = 1
    static let binaryHeaderSize = 12

    /// Binary frame: u32 seq | u64 captureTsMs (big-endian) | opus packet.
    static func packAudioFrame(seq: UInt32, captureTsMs: UInt64, payload: Data) -> Data {
        var data = Data(capacity: binaryHeaderSize + payload.count)
        withUnsafeBytes(of: seq.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: captureTsMs.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static let encoder: JSONEncoder = .init()
    static let decoder: JSONDecoder = .init()
}

// MARK: - Shared payloads

struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    let t0: Double
    let t1: Double
    let speaker: String
    let text: String

    var id: String { "\(t0)-\(t1)-\(speaker)-\(text.hashValue)" }
}

// MARK: - Client -> server

struct HelloMessage: Encodable, Sendable {
    var type = "hello"
    var version = WireProtocol.version
    let token: String
    let sessionId: String?
    var codec = "opus"
    var sampleRate: Int
    var frameMs: Int

    enum CodingKeys: String, CodingKey {
        case type, version, token, codec
        case sessionId = "session_id"
        case sampleRate = "sample_rate"
        case frameMs = "frame_ms"
    }
}

struct StopMessage: Encodable, Sendable {
    var type = "stop"
}

struct AnswerRequestMessage: Encodable, Sendable {
    var type = "answer_request"
    let requestId: Int
    let pressedAtMs: Int64
    let contextSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case pressedAtMs = "pressed_at_ms"
        case contextSeconds = "context_seconds"
    }
}

struct PingMessage: Encodable, Sendable {
    var type = "ping"
    let tMs: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case tMs = "t_ms"
    }
}

// MARK: - Server -> client

struct HelloAck: Decodable, Equatable, Sendable {
    let sessionId: String
    let resumed: Bool
    let serverTimeMs: Int64

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case resumed
        case serverTimeMs = "server_time_ms"
    }
}

struct TranscriptUpdate: Decodable, Equatable, Sendable {
    let segments: [TranscriptSegment]
    let partial: [TranscriptSegment]
    let committedUntil: Double

    enum CodingKeys: String, CodingKey {
        case segments, partial
        case committedUntil = "committed_until"
    }
}

struct AnswerLatency: Decodable, Equatable, Sendable {
    let windowMs: Double
    let geminiMs: Double
    let totalMs: Double

    enum CodingKeys: String, CodingKey {
        case windowMs = "window_ms"
        case geminiMs = "gemini_ms"
        case totalMs = "total_ms"
    }
}

struct AnswerPayload: Decodable, Equatable, Sendable {
    let requestId: Int
    let ok: Bool
    let text: String
    let error: String
    let transcriptUsed: String
    let latency: AnswerLatency

    enum CodingKeys: String, CodingKey {
        case ok, text, error, latency
        case requestId = "request_id"
        case transcriptUsed = "transcript_used"
    }
}

struct ServerErrorMessage: Decodable, Equatable, Sendable {
    let code: String
    let message: String
}

/// Discriminated decode of any server -> client JSON message.
enum ServerMessage: Equatable, Sendable {
    case helloAck(HelloAck)
    case transcript(TranscriptUpdate)
    case answerPending(requestId: Int)
    case answerDelta(requestId: Int, text: String)
    case answer(AnswerPayload)
    case pong(tMs: Int64, serverTimeMs: Int64)
    case serverError(ServerErrorMessage)
    case unknown(type: String)

    static func decode(_ text: String) throws -> ServerMessage {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not utf-8"))
        }
        let envelope = try WireProtocol.decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "hello_ack":
            return try .helloAck(WireProtocol.decoder.decode(HelloAck.self, from: data))
        case "transcript":
            return try .transcript(WireProtocol.decoder.decode(TranscriptUpdate.self, from: data))
        case "answer_pending":
            struct Pending: Decodable {
                let requestId: Int
                enum CodingKeys: String, CodingKey { case requestId = "request_id" }
            }
            return try .answerPending(requestId: WireProtocol.decoder.decode(Pending.self, from: data).requestId)
        case "answer_delta":
            struct Delta: Decodable {
                let requestId: Int
                let text: String
                enum CodingKeys: String, CodingKey {
                    case text
                    case requestId = "request_id"
                }
            }
            let delta = try WireProtocol.decoder.decode(Delta.self, from: data)
            return .answerDelta(requestId: delta.requestId, text: delta.text)
        case "answer":
            return try .answer(WireProtocol.decoder.decode(AnswerPayload.self, from: data))
        case "pong":
            struct Pong: Decodable {
                let tMs: Int64
                let serverTimeMs: Int64
                enum CodingKeys: String, CodingKey {
                    case tMs = "t_ms"
                    case serverTimeMs = "server_time_ms"
                }
            }
            let pong = try WireProtocol.decoder.decode(Pong.self, from: data)
            return .pong(tMs: pong.tMs, serverTimeMs: pong.serverTimeMs)
        case "error":
            return try .serverError(WireProtocol.decoder.decode(ServerErrorMessage.self, from: data))
        case "status":
            return .unknown(type: "status")
        default:
            return .unknown(type: envelope.type)
        }
    }

    private struct Envelope: Decodable {
        let type: String
    }
}

func encodeJSON(_ value: some Encodable) -> String {
    guard let data = try? WireProtocol.encoder.encode(value),
          let text = String(data: data, encoding: .utf8)
    else {
        assertionFailure("protocol message failed to encode")
        return "{}"
    }
    return text
}
