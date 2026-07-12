import Foundation
import os
import SwiftUI

/// Central state machine + orchestration: audio engine -> WebSocket -> UI.
@MainActor
@Observable
final class AppModel {
    // MARK: - UI-facing state

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case recording
        case reconnecting
        case error(String)

        var label: String {
            switch self {
            case .disconnected: "Getrennt"
            case .connecting: "Verbinde…"
            case .connected: "Verbunden"
            case .recording: "Nimmt auf"
            case .reconnecting: "Neu verbinden…"
            case .error: "Fehler"
            }
        }

        var color: Color {
            switch self {
            case .disconnected: .gray
            case .connecting, .reconnecting: .orange
            case .connected: .blue
            case .recording: .green
            case .error: .red
            }
        }
    }

    private(set) var phase: Phase = .disconnected
    private(set) var isTranscribing = false
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partial: [TranscriptSegment] = []
    private(set) var answers = AnswerTracker()
    private(set) var lastRoundTripMs: Double?
    private(set) var sessionId: String?
    private(set) var recordingStartedAt: Date?
    var bannerMessage: String?

    let settings = AppSettings()
    let timetable: TimetableStore

    // MARK: - Internals

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "app")
    private let client = WebSocketClient()
    private let audio = AudioCaptureEngine()
    private var eventPump: Task<Void, Never>?
    private var transcribingPulse: Task<Void, Never>?
    private var timetablePoll: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var wantsRecording = false

    init() {
        timetable = TimetableStore(settings: settings)
        audio.onPacket = { [client] packet in
            client.sendAudioFrame(
                WireProtocol.packAudioFrame(
                    seq: packet.seq, captureTsMs: packet.captureTsMs, payload: packet.payload
                )
            )
        }
        // Interruptions (call/Siri/route loss) no longer stop the session:
        // the capture engine retries on its own — essential when the device
        // is locked in a pocket and nobody can tap. The WebSocket stays up;
        // the gap lands on the server timeline as silence.
        audio.onInterruption = { [weak self] message in
            Task { @MainActor in
                self?.bannerMessage = message
            }
        }
        audio.onResumed = { [weak self] in
            Task { @MainActor in
                self?.bannerMessage = nil
            }
        }
        eventPump = Task { [weak self] in
            guard let events = await self?.client.events() else { return }
            for await event in events {
                await self?.handle(event)
            }
        }
        // Poll the timetable so the Live tab shows the current lesson and
        // auto-stop tracks the period boundary.
        timetablePoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.timetable.refresh()
                self?.scheduleAutoStopIfNeeded()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { [weak self] in await self?.syncTimetableNotifications() }
    }

    // MARK: - Timetable (tiers 2 + 4)

    /// (Re)schedule start-of-lesson notifications from the current settings.
    func syncTimetableNotifications() async {
        await timetable.syncNotifications(enabled: settings.lessonNotifications)
    }

    func refreshTimetable() async {
        await timetable.refresh()
        scheduleAutoStopIfNeeded()
    }

    /// Stop recording when the current lesson ends (if enabled). Rescheduled on
    /// every timetable poll and when recording starts.
    private func scheduleAutoStopIfNeeded() {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard wantsRecording, settings.autoStopAtLessonEnd,
              let end = timetable.current?.endDate, end > Date()
        else { return }
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.wantsRecording else { return }
            self.bannerMessage = "Stunde beendet — Aufnahme automatisch gestoppt."
            self.stopRecording()
        }
    }

    // MARK: - User intents

    func startRecording() async {
        bannerMessage = nil
        guard settings.isConfigured, let url = settings.websocketURL else {
            phase = .error("Set the server address and token in Settings first.")
            return
        }
        guard await AudioCaptureEngine.requestPermission() else {
            phase = .error("Microphone access denied. Enable it in iOS Settings.")
            return
        }
        do {
            try audio.start(bitrate: settings.bitrate)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        wantsRecording = true
        segments = []
        partial = []
        answers.reset()
        scheduleAutoStopIfNeeded()
        await client.connect(to: .init(url: url, token: settings.authToken))
    }

    func stopRecording() {
        wantsRecording = false
        recordingStartedAt = nil
        lastRoundTripMs = nil
        audio.stop()
        answers.failAllInflight(error: "Recording stopped")
        Task { await client.disconnect(sendStop: true) }
        phase = .disconnected
        isTranscribing = false
    }

    func pressAnswerButton() {
        guard phase == .recording || phase == .connected else {
            bannerMessage = "Not connected — the answer button needs a live session."
            return
        }
        let id = answers.begin()
        Task {
            let sent = await client.sendAnswerRequest(
                requestId: id, contextSeconds: settings.contextSeconds
            )
            if !sent {
                answers.complete(id: id, ok: false, text: "",
                                 error: "Not connected to the server", latencyMs: 0)
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: WebSocketClient.Event) {
        switch event {
        case .state(let state):
            applyConnectionState(state)
        case .helloAck(let ack):
            sessionId = ack.sessionId
            if !ack.resumed {
                audio.resetSequence()
                segments = []
                partial = []
            }
        case .transcript(let update):
            segments.append(contentsOf: update.segments)
            if segments.count > 500 {
                segments.removeFirst(segments.count - 500)
            }
            partial = update.partial
            pulseTranscribing()
        case .answerPending(let requestId):
            answers.markAcknowledged(id: requestId)
        case .answerDelta(let requestId, let text):
            answers.appendDelta(id: requestId, text: text)
        case .answer(let payload):
            answers.complete(
                id: payload.requestId,
                ok: payload.ok,
                text: payload.text,
                error: payload.error,
                latencyMs: payload.latency.totalMs
            )
        case .serverError(let err):
            log.warning("server error \(err.code): \(err.message)")
            if err.code == "session_limit" {
                bannerMessage = "Maximum session length reached — recording stopped."
                stopRecording()
            }
        case .roundTrip(let ms):
            lastRoundTripMs = ms
        }
    }

    private func applyConnectionState(_ state: WebSocketClient.ConnectionState) {
        switch state {
        case .disconnected:
            phase = wantsRecording ? .reconnecting : .disconnected
        case .connecting:
            phase = .connecting
        case .connected:
            phase = wantsRecording && audio.running ? .recording : .connected
            if phase == .recording && recordingStartedAt == nil {
                recordingStartedAt = Date()
            }
        case .reconnecting:
            phase = .reconnecting
        case .failed(let reason):
            phase = .error(reason)
            wantsRecording = false
            audio.stop()
        }
    }

    /// "Transcribing" indicator: on while transcript updates keep arriving.
    private func pulseTranscribing() {
        isTranscribing = true
        transcribingPulse?.cancel()
        transcribingPulse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.isTranscribing = false
        }
    }
}
