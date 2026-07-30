import Foundation
import os

/// WebSocket client for the mosslive backend over Tailscale.
///
/// Responsibilities: handshake (hello/hello_ack), automatic reconnection with
/// jittered exponential backoff, session resumption, keepalive pings, and a
/// typed event stream for the UI layer. Audio frames enter a disk-backed FIFO,
/// so reconnecting never grows an in-memory array and packets remain ordered.
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
        /// Seconds of recorded audio waiting in the offline backlog (0 once
        /// the replay has caught up) — drives the "wird gepuffert" banner.
        case buffered(seconds: Double)
        case audioEvent(AudioDiagnosticEvent)
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
    private var closedAfterFatalError = false
    private var pingSentAt: [Int64: ContinuousClock.Instant] = [:]

    private var eventContinuation: AsyncStream<Event>.Continuation?
    private enum IngressSignal: Sendable {
        case dataAvailable
        case failed(String)
    }

    private nonisolated let spool = DiskAudioSpool()
    private let ingressSignals: AsyncStream<IngressSignal>
    private nonisolated let ingressContinuation: AsyncStream<IngressSignal>.Continuation
    private var audioSender: Task<Void, Never>?
    private var spoolID = UUID()

    // Offline-safety tuning for the disk-backed send backlog.
    private static let pacingThresholdFrames = 250 // >5 s unsent ⇒ we're catching up
    private static let pacingBurst = 8 // send this many, then sleep ⇒ ~8× real time
    private static let pacingSleep = Duration.milliseconds(20)

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        // Frames themselves live in a length-prefixed disk file. This stream is
        // only a coalescing wake-up signal, so an outage cannot grow RAM use.
        (ingressSignals, ingressContinuation) = AsyncStream.makeStream(
            of: IngressSignal.self, bufferingPolicy: .bufferingNewest(8)
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

    /// Must run before the microphone starts so even the first Opus packet has
    /// a durable destination.
    func beginRecording() throws {
        spoolID = UUID()
        let orphaned = try spool.begin(id: spoolID)
        if orphaned > 0 {
            emit(
                .audioEvent(
                    AudioDiagnosticEvent(
                        kind: .lostAudio,
                        message: "\(orphaned) alte Netzwerkpakete konnten keiner neuen Sitzung zugeordnet werden"
                    )
                )
            )
        }
        startAudioSender(ingressSignals)
    }

    func cancelPreparedRecording() {
        spool.finish()
    }

    func connect(to endpoint: Endpoint) {
        self.endpoint = endpoint
        userInitiatedClose = false
        closedAfterFatalError = false
        backoff.reset()
        openSocket(resume: false)
    }

    @discardableResult
    func disconnect(sendStop: Bool) async -> Int {
        userInitiatedClose = true
        reconnectTask?.cancel()
        // Preserve protocol order: all queued audio must precede the stop
        // message. If the socket is down, drainSpool returns immediately and
        // the remaining count is recorded below.
        await drainSpool()
        if sendStop, let task, task.state == .running {
            try? await task.send(.string(encodeJSON(StopMessage())))
            // give the server a moment to finalize before the close frame
            try? await Task.sleep(for: .milliseconds(300))
        }
        let pending = spool.status().pendingFrames
        if pending > 0 {
            emit(
                .audioEvent(
                    AudioDiagnosticEvent(
                        kind: .transport,
                        message: "Aufnahme beendet; \(pending) Netzwerkpakete verbleiben im Datei-Puffer"
                    )
                )
            )
        }
        teardownSocket(code: .normalClosure)
        spool.finish()
        sessionId = nil
        emit(.state(.disconnected))
        return pending
    }

    // MARK: - Sending

    /// Fire-and-forget audio. Never throws, never blocks the audio path.
    ///
    /// Frames go through a single-consumer queue so they hit the wire in strict
    /// sequence order. (Spawning one Task per packet gives no ordering
    /// guarantee: packets arrived shuffled, the server logged them as
    /// lost/reordered, and the stateful Opus decoder degraded on every swap.)
    nonisolated func sendAudioFrame(_ frame: Data) {
        do {
            try spool.append(frame)
            ingressContinuation.yield(.dataAvailable)
        } catch {
            ingressContinuation.yield(.failed(error.localizedDescription))
        }
    }

    private var lastReportedBufferedSeconds = 0.0

    /// Emits backlog progress, throttled to whole-second changes so the UI
    /// isn't updated 50× per second.
    private func reportBuffered() {
        let frames = spool.status().pendingFrames
        let seconds = Double(frames) * Double(AudioPipelineConstants.frameMs) / 1000
        guard seconds.rounded(.down) != lastReportedBufferedSeconds.rounded(.down) else { return }
        lastReportedBufferedSeconds = seconds
        emit(.buffered(seconds: seconds))
    }

    /// Send one frame if connected. Returns false when the socket is down (the
    /// caller keeps the frame buffered) or the send failed. Kept on the actor so
    /// the socket never crosses an isolation boundary.
    private func trySendFrame(_ data: Data) async -> Bool {
        guard let task, task.state == .running else { return false }
        do {
            try await task.send(.data(data))
            return true
        } catch {
            return false // receive loop notices and reconnects; frame stays buffered
        }
    }

    /// The single audio consumer. Frame bytes stay in DiskAudioSpool:
    /// * Online: records are acknowledged in strict order after successful send.
    /// * Offline: records remain in the spool file and RAM stays bounded.
    /// * On reconnect the server keeps the same session (long resume grace) and
    ///   the whole backlog is replayed. The replay is paced to ~8× real time so
    ///   the server's transcriber keeps up and never has to skip audio.
    private func startAudioSender(_ signals: AsyncStream<IngressSignal>) {
        guard audioSender == nil else { return }
        audioSender = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                switch signal {
                case .dataAvailable:
                    await self.drainSpool()
                case .failed(let message):
                    await self.emit(
                        .audioEvent(
                            AudioDiagnosticEvent(
                                kind: .lostAudio,
                                message: "Audio konnte nicht in den Datei-Puffer geschrieben werden: \(message)"
                            )
                        )
                    )
                }
                await self.reportBuffered()
            }
        }
    }

    private func drainSpool() async {
        guard let task, task.state == .running else { return }
        var burst = 0
        while task.state == .running {
            let frame: Data
            do {
                guard let next = try spool.peek() else { break }
                frame = next
            } catch {
                emit(
                    .audioEvent(
                        AudioDiagnosticEvent(
                            kind: .lostAudio,
                            message: "Datei-Puffer ist beschädigt: \(error.localizedDescription)"
                        )
                    )
                )
                break
            }
            guard await trySendFrame(frame) else { break }
            spool.acknowledge(frame)
            if spool.status().pendingFrames > Self.pacingThresholdFrames {
                burst += 1
                if burst >= Self.pacingBurst {
                    burst = 0
                    try? await Task.sleep(for: Self.pacingSleep)
                }
            }
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
            if userInitiatedClose {
                // expected close (stop flow) — let the UI settle, but never
                // overwrite a fatal error state (e.g. rejected token)
                if !closedAfterFatalError {
                    emit(.state(.disconnected))
                }
                return
            }
            guard self.task === task else { return }
            let closeCode = task.closeCode
            log.warning("connection dropped: \(error.localizedDescription) close=\(closeCode.rawValue)")
            if closeCode.rawValue == 4401 {
                emit(.state(.failed(reason: "Server hat das Auth-Token abgelehnt. Einstellungen prüfen.")))
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
                // A resume attempt that came back as a new session (grace
                // expired after a very long outage): the backlog is for the old
                // session's sequence space, so discard it before replaying.
                if sessionId != nil {
                    let discarded = (try? spool.discardAndRestart(id: UUID())) ?? 0
                    if discarded > 0 {
                        emit(
                            .audioEvent(
                                AudioDiagnosticEvent(
                                    kind: .lostAudio,
                                    message: "Server-Sitzung abgelaufen; \(discarded) gepufferte Pakete verworfen"
                                )
                            )
                        )
                    }
                }
                sessionId = ack.sessionId
            }
            backoff.reset()
            startKeepalive()
            emit(.helloAck(ack))
            emit(.state(.connected(sessionId: ack.sessionId)))
            ingressContinuation.yield(.dataAvailable)
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
                closedAfterFatalError = true
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
