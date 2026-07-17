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
    }

    private(set) var phase: Phase = .disconnected
    private(set) var isTranscribing = false
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partial: [TranscriptSegment] = []
    private(set) var lastRoundTripMs: Double?
    /// Seconds of audio held in the offline backlog (0 while connected/caught
    /// up) — shown so an outage in class reads as "buffered", not "lost".
    private(set) var bufferedSeconds: Double = 0
    /// Rolling window of real microphone levels (0...1) for the live
    /// waveform; newest last.
    private(set) var micLevels: [Float] = []
    private(set) var sessionId: String?
    private(set) var recordingStartedAt: Date?
    var bannerMessage: String?

    let settings = AppSettings()
    let timetable: TimetableStore
    let chat = ChatStore()

    // MARK: - Internals

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "app")
    private let client = WebSocketClient()
    private let audio = AudioCaptureEngine()
    private var eventPump: Task<Void, Never>?
    private var transcribingPulse: Task<Void, Never>?
    private var timetablePoll: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var wantsRecording = false
    private var lastNotificationSyncDay = Date.distantPast

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
        audio.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.micLevels.append(level)
                if self.micLevels.count > 72 {
                    self.micLevels.removeFirst(self.micLevels.count - 72)
                }
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
                await self?.resyncNotificationsIfDayChanged()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { [weak self] in await self?.syncTimetableNotifications() }
    }

    // MARK: - Timetable (tiers 2 + 4)

    /// (Re)schedule start-of-lesson notifications from the current settings.
    func syncTimetableNotifications() async {
        lastNotificationSyncDay = Date()
        await timetable.syncNotifications(enabled: settings.lessonNotifications)
    }

    /// Notifications only cover the day they were scheduled on. When the app
    /// stays open (or suspended) past midnight, the next day's lessons must
    /// be scheduled too — checked on every timetable poll.
    private func resyncNotificationsIfDayChanged() async {
        guard settings.lessonNotifications,
              !Calendar.current.isDate(lastNotificationSyncDay, inSameDayAs: Date())
        else { return }
        await syncTimetableNotifications()
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
            self.bannerMessage = "Stunde beendet. Die Aufnahme wurde automatisch gestoppt."
            self.stopRecording()
        }
    }

    // MARK: - User intents

    func startRecording() async {
        bannerMessage = nil
        guard settings.isConfigured, let url = settings.websocketURL else {
            phase = .error("Zuerst Serveradresse und Token in den Einstellungen setzen.")
            return
        }
        guard await AudioCaptureEngine.requestPermission() else {
            phase = .error("Mikrofonzugriff verweigert. In den iOS-Einstellungen erlauben.")
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
        micLevels = []
        scheduleAutoStopIfNeeded()
        await client.connect(to: .init(url: url, token: settings.authToken))
    }

    func stopRecording() {
        wantsRecording = false
        recordingStartedAt = nil
        lastRoundTripMs = nil
        bufferedSeconds = 0
        audio.stop()
        Task { await client.disconnect(sendStop: true) }
        phase = .disconnected
        isTranscribing = false
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
        case .answerPending, .answerDelta, .answer:
            // In-app answers are gone; the widget's HTTP answers get mirrored
            // over this socket, so the frames must still be consumed silently.
            break
        case .serverError(let err):
            log.warning("server error \(err.code): \(err.message)")
            if err.code == "session_limit" {
                bannerMessage = "Maximale Sitzungslänge erreicht. Die Aufnahme wurde gestoppt."
                stopRecording()
            }
        case .roundTrip(let ms):
            lastRoundTripMs = ms
        case .buffered(let seconds):
            bufferedSeconds = seconds
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
