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
    private(set) var audioDiagnostics = AudioDiagnosticsSnapshot()
    private(set) var audioEvents: [AudioDiagnosticEvent] = []
    private(set) var localRecordings: [LocalRecordingSummary] = []
    private(set) var serverTranscriptLagSeconds: Double?
    private(set) var sessionId: String?
    private(set) var recordingStartedAt: Date?
    var bannerMessage: String?

    /// Which place of the app the sidebar is on. Held here rather than in the
    /// shell so a screen can send the student somewhere that answers its empty
    /// state ("Zur Aufnahme") instead of describing it.
    var selectedTab: AppTab? = .aufnahme

    // MARK: - Studying

    /// The round on screen. Presented as a full-screen modal by the shell, so
    /// studying is a mode with one way out rather than a page inside a tab.
    private(set) var studySession: StudySession?
    /// A round that was interrupted hard enough to lose its modal — killed for
    /// memory, mostly. Heute offers to pick it up rather than reopening it
    /// over whatever the student meant to do.
    private(set) var resumableSession: StudySession?

    let settings = AppSettings()
    let timetable: TimetableStore
    let chat = ChatStore()
    /// Whether the server can be reached — every screen asks this before it
    /// decides between live content and what it has stored.
    let connectivity = Connectivity.shared
    /// Reviews answered while it could not.
    let reviews = ReviewQueue()

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
        audio.onDiagnostics = { [weak self] snapshot in
            Task { @MainActor in
                self?.audioDiagnostics = snapshot
            }
        }
        audio.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.appendAudioEvent(event)
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
                // The same poll doubles as the heartbeat that notices the
                // server coming back, which is when anything answered offline
                // can finally be handed over.
                await self?.flushQueuedReviews()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { [weak self] in await self?.syncTimetableNotifications() }
        Task { [weak self] in await self?.recoverInterruptedRecordings() }
        resumableSession = StudySession.restore()
    }

    // MARK: - Studying

    func startStudy(_ session: StudySession) {
        resumableSession = nil
        studySession = session
    }

    /// Pick up the interrupted round exactly where it stopped.
    func resumeStudy() {
        guard let resumableSession else { return }
        studySession = resumableSession
        self.resumableSession = nil
    }

    /// Leave the round. Answers are already reported or queued, so there is
    /// nothing here to save — only the resume point to throw away.
    func endStudy() {
        studySession?.discard()
        studySession = nil
        resumableSession = nil
    }

    /// Hand one answer to the schedule, or to the queue when there is no server.
    ///
    /// Practice never reports: the whole point of it is that going over Tuesday
    /// again does not push Tuesday's cards up the ladder.
    func record(
        answer card: BackendAPI.LearnCard,
        correct: Bool,
        rating: Int,
        responseMs: Int,
        confidence: Int?,
        in session: StudySession
    ) {
        guard session.mode.reportsResults else { return }
        let client = api
        let mode = session.mode.apiName
        Task {
            await self.reviews.record(
                cardId: card.id,
                correct: correct,
                rating: rating,
                responseMs: responseMs,
                confidence: confidence,
                mode: mode,
                api: client
            )
        }
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

    /// The backend client for the configured server.
    var api: BackendAPI {
        BackendAPI(host: settings.serverHost, port: settings.serverPort, token: settings.authToken)
    }

    /// Hand over anything answered while the server was away.
    func flushQueuedReviews() async {
        guard connectivity.isOnline, settings.isConfigured, !reviews.pending.isEmpty else { return }
        await reviews.flush(api: api)
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
            try await client.beginRecording()
            try audio.start(bitrate: settings.bitrate)
        } catch {
            await client.cancelPreparedRecording()
            phase = .error(error.localizedDescription)
            return
        }
        wantsRecording = true
        segments = []
        partial = []
        micLevels = []
        audioEvents = []
        audioDiagnostics = AudioDiagnosticsSnapshot()
        serverTranscriptLagSeconds = nil
        scheduleAutoStopIfNeeded()
        await client.connect(to: .init(url: url, token: settings.authToken))
    }

    func stopRecording() {
        wantsRecording = false
        recordingStartedAt = nil
        lastRoundTripMs = nil
        serverTranscriptLagSeconds = nil
        bufferedSeconds = 0
        let manifestURL = audio.stop()
        Task { [weak self] in
            let pending = await client.disconnect(sendStop: true)
            if let manifestURL {
                if pending > 0 {
                    LocalRecordingStorage.append(
                        AudioDiagnosticEvent(
                            kind: .transport,
                            message: "\(pending) Netzwerkpakete waren beim Beenden noch nicht übertragen"
                        ),
                        to: manifestURL
                    )
                }
                _ = await LocalRecordingRecovery.finalize(manifestURL: manifestURL, recovered: false)
                await self?.refreshLocalRecordings()
            }
        }
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
            audio.attachServerSession(ack.sessionId)
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
            if let recordingStartedAt {
                let elapsed = Date().timeIntervalSince(recordingStartedAt)
                serverTranscriptLagSeconds = max(0, elapsed - update.committedUntil)
            }
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
            } else if err.code == "server_busy" {
                bannerMessage =
                    "Die manuelle 48-kHz-Neutranskription läuft noch. Audio wird lokal gepuffert."
            }
        case .roundTrip(let ms):
            lastRoundTripMs = ms
        case .buffered(let seconds):
            bufferedSeconds = seconds
        case .audioEvent(let event):
            audio.recordExternalEvent(event)
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
            let manifestURL = audio.stop()
            Task { [weak self] in
                let pending = await client.disconnect(sendStop: false)
                if let manifestURL {
                    if pending > 0 {
                        LocalRecordingStorage.append(
                            AudioDiagnosticEvent(
                                kind: .transport,
                                message: "\(pending) Netzwerkpakete nach Verbindungsfehler nicht übertragen"
                            ),
                            to: manifestURL
                        )
                    }
                    _ = await LocalRecordingRecovery.finalize(manifestURL: manifestURL, recovered: false)
                    await self?.refreshLocalRecordings()
                }
            }
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

    func refreshLocalRecordings() async {
        guard let root = try? LocalRecordingStorage.defaultRoot() else { return }
        localRecordings = LocalRecordingStorage.summaries(root: root)
    }

    private func recoverInterruptedRecordings() async {
        guard let root = try? LocalRecordingStorage.defaultRoot() else { return }
        let recovered = await LocalRecordingRecovery.recoverPending(root: root)
        localRecordings = LocalRecordingStorage.summaries(root: root)
        if !recovered.isEmpty {
            bannerMessage = recovered.count == 1
                ? "Eine unterbrochene Sicherheitsaufnahme wurde wiederhergestellt."
                : "\(recovered.count) unterbrochene Sicherheitsaufnahmen wurden wiederhergestellt."
            for item in recovered {
                appendAudioEvent(
                    AudioDiagnosticEvent(
                        kind: .recovered,
                        message: "Sicherheitsaufnahme vom \(item.startedAt.formatted()) wiederhergestellt"
                    )
                )
            }
        }
    }

    private func appendAudioEvent(_ event: AudioDiagnosticEvent) {
        audioEvents.insert(event, at: 0)
        if audioEvents.count > 100 {
            audioEvents.removeLast(audioEvents.count - 100)
        }
    }
}
