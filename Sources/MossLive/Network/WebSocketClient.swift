import Foundation
import os

/// WebSocket client for the mosslive backend over Tailscale.
///
/// Responsibilities: handshake (hello/hello_ack), automatic reconnection with
/// jittered exponential backoff, session resumption, keepalive pings, and a
/// typed event stream for the UI layer. Audio frames are fire-and-forget: when
/// the socket is down they are dropped (the sequence number keeps advancing at
/// the encoder, so the server records the outage as silence and the session
/// timeline stays aligned with wall time).
actor WebSocketClient {
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(sessionId: String)
        case reconnecting(attempt: Int)
        case failed(reason: String)
    }

    enum Event: Sendable {
        case state(ConnectionState)
        case helloAck(HelloAck)
        case transcript(TranscriptUpdate)
        case answerPending(requestId: Int)
        case answerDelta(requestId: Int, text: String)
        case answer(AnswerPayload)
        case serverError(ServerErrorMessage)
        case roundTrip(ms: Double)
    }

    struct Endpoint: Sendable {
        let url: URL
        let token: String
    }

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "ws")
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var keepaliveLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var backoff = BackoffPolicy()
    private var endpoint: Endpoint?
    private var sessionId: String?
    private var userInitiatedClose = true
    private var pingSentAt: [Int64: ContinuousClock.Instant] = [:]

    private var eventContinuation: AsyncStream<Event>.Continuation?
    private let audioFrames: AsyncStream<Data>
    private nonisolated let audioContinuation: AsyncStream<Data>.Continuation
    private var audioSender: Task<Void, Never>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        // ~5 s of audio buffered while reconnecting; older frames drop first
        (audioFrames, audioContinuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(256)
        )
    }

    /// Single consumer (AppModel) subscribes once.
    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    private func emit(_ event: Event) {
        eventContinuation?.yield(event)
    }

    // MARK: - Lifecycle

    func connect(to endpoint: Endpoint) {
        self.endpoint = endpoint
        userInitiatedClose = false
        backoff.reset()
        startAudioSender(audioFrames)
        openSocket(resume: false)
    }

    func disconnect(sendStop: Bool) async {
        userInitiatedClose = true
        reconnectTask?.cancel()
        if sendStop, let task, task.state == .running {
            try? await task.send(.string(encodeJSON(StopMessage())))
            // give the server a moment to finalize before the close frame
            try? await Task.sleep(for: .milliseconds(300))
        }
        teardownSocket(code: .normalClosure)
        sessionId = nil
        emit(.state(.disconnected))
    }

    // MARK: - Sending

    /// Fire-and-forget audio. Never throws, never blocks the audio path.
    ///
    /// Frames go through a single-consumer queue so they hit the wire in
    /// strict sequence order. (Spawning one Task per packet — the previous
    /// implementation — gives no ordering guarantee: packets arrived shuffled,
    /// the server logged them as lost/reordered, and the stateful Opus decoder
    /// degraded on every swap.) When the socket is down, the bounded buffer
    /// drops oldest frames; sequence numbers keep advancing, so the gap lands
    /// on the server timeline as silence with correct timestamps.
    nonisolated func sendAudioFrame(_ frame: Data) {
        audioContinuation.yield(frame)
    }

    private func startAudioSender(_ frames: AsyncStream<Data>) {
        guard audioSender == nil else { return }
        audioSender = Task { [weak self] in
            for await frame in frames {
                await self?.sendBinary(frame)
            }
        }
    }

    private func sendBinary(_ data: Data) async {
        guard let task, task.state == .running else { return }
        do {
            try await task.send(.data(data))
        } catch {
            // receive loop notices the failure and reconnects
        }
    }

    func sendAnswerRequest(requestId: Int, contextSeconds: Double?) async -> Bool {
        guard let task, task.state == .running else { return false }
        let msg = AnswerRequestMessage(
            requestId: requestId,
            pressedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            contextSeconds: contextSeconds
        )
        do {
            try await task.send(.string(encodeJSON(msg)))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Socket plumbing

    private func openSocket(resume: Bool) {
        guard let endpoint else { return }
        teardownSocket(code: .goingAway)
        emit(.state(resume ? .reconnecting(attempt: backoff.attempt) : .connecting))

        let task = session.webSocketTask(with: endpoint.url)
        task.maximumMessageSize = 64 * 1024
        self.task = task
        task.resume()

        let hello = HelloMessage(
            token: endpoint.token,
            sessionId: sessionId,
            sampleRate: AudioPipelineConstants.sampleRate,
            frameMs: AudioPipelineConstants.frameMs
        )
        receiveLoop = Task { [weak self] in
            await self?.runConnection(task: task, helloJSON: encodeJSON(hello))
        }
    }

    private func runConnection(task: URLSessionWebSocketTask, helloJSON: String) async {
        do {
            try await task.send(.string(helloJSON))
            while !Task.isCancelled {
                let message = try await task.receive()
                if case let .string(text) = message {
                    try handleServerText(text)
                }
            }
        } catch {
            guard !userInitiatedClose, self.task === task else { return }
            let closeCode = task.closeCode
            log.warning("connection dropped: \(error.localizedDescription) close=\(closeCode.rawValue)")
            if closeCode.rawValue == 4401 {
                emit(.state(.failed(reason: "Server rejected the auth token. Check Settings.")))
                return
            }
            scheduleReconnect()
        }
    }

    private func handleServerText(_ text: String) throws {
        let message = try ServerMessage.decode(text)
        switch message {
        case .helloAck(let ack):
            if !ack.resumed {
                sessionId = ack.sessionId
            }
            backoff.reset()
            startKeepalive()
            emit(.helloAck(ack))
            emit(.state(.connected(sessionId: ack.sessionId)))
        case .transcript(let update):
            emit(.transcript(update))
        case .answerPending(let requestId):
            emit(.answerPending(requestId: requestId))
        case .answerDelta(let requestId, let text):
            emit(.answerDelta(requestId: requestId, text: text))
        case .answer(let payload):
            emit(.answer(payload))
        case .pong(let tMs, _):
            if let sent = pingSentAt.removeValue(forKey: tMs) {
                let elapsed = (ContinuousClock.now - sent).components
                let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                emit(.roundTrip(ms: ms))
            }
        case .serverError(let err):
            if err.code == "unauthorized" || err.code == "bad_protocol" {
                // fatal handshake rejection: reconnecting would loop forever,
                // so stop and surface the server's reason instead
                userInitiatedClose = true
                teardownSocket(code: .normalClosure)
                emit(.state(.failed(reason: err.message)))
            } else {
                emit(.serverError(err))
            }
        case .unknown:
            break
        }
    }

    private func startKeepalive() {
        keepaliveLoop?.cancel()
        keepaliveLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.sendPing()
            }
        }
    }

    private func sendPing() async {
        guard let task, task.state == .running else { return }
        let tMs = Int64(Date().timeIntervalSince1970 * 1000)
        pingSentAt[tMs] = ContinuousClock.now
        if pingSentAt.count > 8 {
            // pongs are missing; let the receive loop's failure path handle it
            pingSentAt.removeAll()
        }
        try? await task.send(.string(encodeJSON(PingMessage(tMs: tMs))))
    }

    private func scheduleReconnect() {
        guard !userInitiatedClose else { return }
        let delay = backoff.nextDelay()
        emit(.state(.reconnecting(attempt: backoff.attempt)))
        log.info("reconnecting in \(String(format: "%.2f", delay))s (attempt \(self.backoff.attempt))")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.openSocket(resume: true)
        }
    }

    private func teardownSocket(code: URLSessionWebSocketTask.CloseCode) {
        receiveLoop?.cancel()
        receiveLoop = nil
        keepaliveLoop?.cancel()
        keepaliveLoop = nil
        pingSentAt.removeAll()
        task?.cancel(with: code, reason: nil)
        task = nil
    }
}
