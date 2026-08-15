import Foundation
import Observation
import os
import SwiftUI

extension Notification.Name {
    /// Sent synchronously before the system split view starts changing width.
    static let readerContainerWillResize = Notification.Name("MossLive.readerContainerWillResize")
}

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
    private(set) var recordingSubjectSelection = RecordingSubjectSelection()
    private(set) var isSavingRecordingSubject = false
    private(set) var recordingSubjectError: String?
    var bannerMessage: String?

    /// Which place of the app the sidebar is on. Held here rather than in the
    /// shell so a screen can send the student somewhere that answers its empty
    /// state ("Zur Aufnahme") instead of describing it.
    var selectedTab: AppTab? = .aufnahme

    /// Kept on the shared model so a pushed reader can prepare its expensive
    /// PDF surface before the system starts resizing the split view.
    var columnVisibility: NavigationSplitViewVisibility = .all

    let settings: AppSettings
    let aiConfiguration: AIConfigurationStore
    let timetable: TimetableStore
    let chat: ChatStore
    /// Whether the server can be reached — every screen asks this before it
    /// decides between live content and what it has stored.
    let connectivity = Connectivity.shared

    // MARK: - Internals

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "app")
    private let client = WebSocketClient()
    private let audio = AudioCaptureEngine()
    private var eventPump: Task<Void, Never>?
    private var transcribingPulse: Task<Void, Never>?
    private var timetablePoll: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var recordingSubjectPersistenceTask: Task<Void, Never>?
    private var recordingSubjectErrorWasDismissed = false
    private var wantsRecording = false
    private var lastNotificationSyncDay = Date.distantPast
    private static let lastRecordingSubjectKey = "last-recording-subject"

    init() {
        settings = AppSettings()
        if UITestRuntime.isEnabled {
            let unavailableScenarios: Set<UITestRuntime.Scenario> = [.offline, .unauthorized, .serverError]
            aiConfiguration = AIConfigurationStore(
                settings: unavailableScenarios.contains(UITestRuntime.scenario) ? nil : UITestRuntime.answerSettings,
                persistOperation: { _, _ in
                    try? await Task.sleep(for: .milliseconds(80))
                }
            )
            chat = ChatStore(loadPersisted: false)
        } else {
            aiConfiguration = AIConfigurationStore()
            chat = ChatStore()
        }
        timetable = TimetableStore(settings: settings)
        if UITestRuntime.isEnabled {
            configureUITestState()
            return
        }
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
                self?.applyCurrentTimetableSubjectIfIdle()
                self?.scheduleAutoStopIfNeeded()
                await self?.resyncNotificationsIfDayChanged()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { [weak self] in await self?.syncTimetableNotifications() }
        Task { [weak self] in await self?.recoverInterruptedRecordings() }
        Task { [weak self] in await self?.refreshRecordingSubjects() }
    }

    // MARK: - Timetable (tiers 2 + 4)

    /// (Re)schedule start-of-lesson notifications from the current settings.
    func syncTimetableNotifications() async {
        lastNotificationSyncDay = Date()
        if UITestRuntime.isEnabled { return }
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
        applyCurrentTimetableSubjectIfIdle()
        scheduleAutoStopIfNeeded()
    }

    func refreshRecordingSubjects() async {
        var subjects = OfflineCache.load(
            [BackendAPI.SubjectInfo].self,
            key: OfflineCache.Key.timetableSubjects
        ) ?? []
        do {
            let fresh = try await api.timetableSubjects()
            subjects = fresh
            OfflineCache.save(fresh, as: OfflineCache.Key.timetableSubjects)
        } catch {
            if subjects.isEmpty { bannerMessage = error.localizedDescription }
        }
        recordingSubjectSelection.refresh(
            catalogue: subjects,
            current: timetable.current,
            lastSelectedID: UserDefaults.standard.string(forKey: Self.lastRecordingSubjectKey)
        )
    }

    private func applyCurrentTimetableSubjectIfIdle() {
        guard !wantsRecording else { return }
        recordingSubjectSelection.refresh(
            catalogue: recordingSubjectSelection.catalogue,
            current: timetable.current,
            lastSelectedID: UserDefaults.standard.string(forKey: Self.lastRecordingSubjectKey)
        )
    }

    func chooseRecordingSubject(_ subject: BackendAPI.SubjectInfo) {
        recordingSubjectSelection.choose(subject)
        UserDefaults.standard.set(subject.id, forKey: Self.lastRecordingSubjectKey)
        recordingSubjectError = nil
        recordingSubjectErrorWasDismissed = false
        guard wantsRecording, let sessionId else { return }
        persistRecordingSubject(subject, sessionId: sessionId)
    }

    func dismissRecordingSubjectError() {
        recordingSubjectError = nil
        recordingSubjectErrorWasDismissed = true
    }

    private func persistRecordingSubject(_ subject: BackendAPI.SubjectInfo, sessionId: String) {
        recordingSubjectPersistenceTask?.cancel()
        if UITestRuntime.isEnabled {
            recordingSubjectSelection.confirm(subject)
            return
        }
        recordingSubjectPersistenceTask = Task { [weak self] in
            guard let self else { return }
            isSavingRecordingSubject = true
            defer { isSavingRecordingSubject = false }

            while !Task.isCancelled,
                  wantsRecording,
                  self.sessionId == sessionId,
                  recordingSubjectSelection.selected == subject {
                do {
                    _ = try await api.updateLessonSubject(
                        sessionId: sessionId,
                        subject: subject.name
                    )
                    guard !Task.isCancelled else { return }
                    recordingSubjectSelection.confirm(subject)
                    recordingSubjectError = nil
                    recordingSubjectErrorWasDismissed = false
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if !recordingSubjectErrorWasDismissed {
                        recordingSubjectError =
                            "Das Fach konnte nicht gespeichert werden: \(error.localizedDescription)"
                    }
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// The backend client for the configured server.
    var api: BackendAPI {
        BackendAPI(host: settings.serverHost, port: settings.serverPort, token: settings.authToken)
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
        if UITestRuntime.isEnabled {
            await startUITestRecording()
            return
        }
        bannerMessage = nil
        recordingSubjectError = nil
        recordingSubjectErrorWasDismissed = false
        guard recordingSubjectSelection.selected != nil else {
            phase = .error("Bitte zuerst ein Fach auswählen.")
            return
        }
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
        sessionId = nil
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
        recordingSubjectPersistenceTask?.cancel()
        recordingSubjectPersistenceTask = nil
        isSavingRecordingSubject = false
        recordingSubjectError = nil
        recordingSubjectErrorWasDismissed = false
        if UITestRuntime.isEnabled {
            wantsRecording = false
            phase = .disconnected
            isTranscribing = false
            recordingStartedAt = nil
            bufferedSeconds = 0
            return
        }
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
        recordingSubjectSelection.resetManualOverride()
        applyCurrentTimetableSubjectIfIdle()
    }

    // MARK: - Event handling

    private func handle(_ event: WebSocketClient.Event) {
        switch event {
        case .state(let state):
            applyConnectionState(state)
        case .helloAck(let ack):
            sessionId = ack.sessionId
            audio.attachServerSession(ack.sessionId)
            if let subject = recordingSubjectSelection.selected {
                persistRecordingSubject(subject, sessionId: ack.sessionId)
            }
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
            recordingSubjectPersistenceTask?.cancel()
            recordingSubjectPersistenceTask = nil
            isSavingRecordingSubject = false
            recordingSubjectError = nil
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

    private func configureUITestState() {
        selectedTab = UITestRuntime.requestedTab ?? .aufnahme
        let subjects = OfflineCache.load(
            [BackendAPI.SubjectInfo].self,
            key: OfflineCache.Key.timetableSubjects
        ) ?? []
        recordingSubjectSelection.refresh(catalogue: subjects, current: timetable.current)
        connectivity.configureForUITests(online: UITestRuntime.scenario != .offline)
        switch UITestRuntime.scenario {
        case .recording:
            applyUITestRecordingState()
        case .reconnecting:
            applyUITestRecordingState()
            phase = .reconnecting
            bufferedSeconds = 83
            bannerMessage = "Die Verbindung wird im Test wiederhergestellt."
        case .serverError:
            phase = .error("Deterministischer Testfehler.")
        case .unauthorized:
            phase = .error("Testzugang abgelehnt.")
        case .offline:
            connectivity.configureForUITests(online: false)
        default:
            break
        }
    }

    private func startUITestRecording() async {
        bannerMessage = nil
        phase = .connecting
        try? await Task.sleep(for: .milliseconds(180))
        applyUITestRecordingState()
    }

    private func applyUITestRecordingState() {
        wantsRecording = true
        phase = .recording
        isTranscribing = true
        recordingStartedAt = Date().addingTimeInterval(-67)
        lastRoundTripMs = 42
        sessionId = "ui-test-session"
        micLevels = (0 ..< 48).map { Float(($0 % 11) + 1) / 14 }
        segments = [
            TranscriptSegment(t0: 0, t1: 5, speaker: "Lehrkraft", text: "Das ist eine Testaufnahme."),
            TranscriptSegment(t0: 5, t1: 11, speaker: "Schüler", text: "Alle Zustände bleiben deterministisch."),
        ]
        partial = [TranscriptSegment(t0: 11, t1: 14, speaker: "Lehrkraft", text: "Gerade wird …")]
        audioDiagnostics = AudioDiagnosticsSnapshot(
            level: 0.48,
            rmsDBFS: -22,
            peakDBFS: -8,
            noiseFloorDBFS: -48,
            clippedSamplePercent: 0.1,
            hardwareSampleRate: 48000,
            hardwareChannels: 1,
            route: "Testmikrofon",
            voiceProcessing: true,
            automaticGainControl: true,
            capturedSeconds: 67,
            lostBuffers: 1,
            interruptions: 1,
            routeChanges: 1
        )
        audioEvents = [
            AudioDiagnosticEvent(kind: .routeChanged, message: "Testaudio auf internes Mikrofon gewechselt"),
            AudioDiagnosticEvent(kind: .started, message: "Deterministische Aufnahme gestartet"),
        ]
    }
}
