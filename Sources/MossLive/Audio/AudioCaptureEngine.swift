import AVFoundation
import Foundation
import os
#if canImport(UIKit)
    import UIKit
#endif

/// Microphone capture -> 16 kHz mono Int16 -> Opus packets.
///
/// Uses AVAudioEngine with a tap on the input node in the hardware format,
/// converts with AVAudioConverter, and hands ~20 ms Opus packets to `onPacket`
/// (called on the audio conversion queue — the consumer must be fast and
/// non-blocking; WebSocketClient.sendAudioFrame is).
///
/// Session config: `.spokenAudio` + AVAudioEngine voice processing applies
/// Apple's device-tuned noise suppression and automatic gain control;
/// `.playAndRecord` + background mode `audio` keeps capture alive when the
/// app is backgrounded or when the iPad lid is closed.
final class AudioCaptureEngine {
    enum CaptureError: LocalizedError {
        case microphoneDenied
        case audioSessionBusy
        case voiceProcessingUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Mikrofonzugriff verweigert. In den iOS-Einstellungen unter Datenschutz > Mikrofon erlauben."
            case .audioSessionBusy:
                "Mikrofon wird von einer anderen App belegt (z. B. ein Discord- oder Telefon-Anruf). "
                    + "Bitte diese App schließen oder den Anruf beenden und erneut starten."
            case .voiceProcessingUnavailable(let reason):
                "Die iOS-Rauschunterdrückung konnte nicht gestartet werden: \(reason)"
            }
        }
    }

    /// A failed `setActive` often means another app (a Discord/FaceTime/phone
    /// call) owns the audio session; translate those OSStatus codes into a
    /// clear message instead of surfacing a cryptic activation error.
    private static func activationError(_ error: Error) -> Error {
        let busy: Set<Int> = [
            AVAudioSession.ErrorCode.insufficientPriority.rawValue,
            AVAudioSession.ErrorCode.isBusy.rawValue,
            AVAudioSession.ErrorCode.cannotStartRecording.rawValue,
            AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue,
        ]
        return busy.contains((error as NSError).code) ? CaptureError.audioSessionBusy : error
    }

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "audio")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var archiveConverter: AVAudioConverter?
    private var encoder: OpusStreamEncoder?
    private var recordingWriter: LocalRecordingWriter?
    private let processingQueue = DispatchQueue(label: "com.fourmbs.mosslive.audio", qos: .userInitiated)
    /// Serializes rebuilding capture (route change, interruption, stall) away
    /// from both the audio queue and the main thread.
    private let controlQueue = DispatchQueue(label: "com.fourmbs.mosslive.audio.control", qos: .userInitiated)
    private(set) var running = false
    private var signalAnalyzer = AudioSignalAnalyzer()
    private var diagnostics = AudioDiagnosticsSnapshot()
    private var interruptionStartedAt: Date?
    /// When the last microphone buffer arrived, and the timer that notices it
    /// stopped arriving. Read and written on `processingQueue`.
    private var lastBufferAt = Date()
    private var stallTimer: DispatchSourceTimer?
    private var stallReported = false
    private var lastResumeAttemptAt = Date.distantPast
    /// Whether the app is in the foreground, and whether capture is waiting for
    /// it. Read and written on the main thread and on `controlQueue`, both of
    /// which only ever read a Bool here.
    private var isForeground = true
    private var wantsRebuildOnForeground = false
    /// So the "waiting in the background" note is written once per outage
    /// rather than every two seconds for as long as dictation is open.
    private var backgroundWaitReported = false
    #if canImport(UIKit)
        private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Called for every encoded packet (already framed for the wire by the caller).
    var onPacket: (@Sendable (OpusStreamEncoder.Packet) -> Void)?
    /// Real microphone level (0...1, roughly every 60 ms) for the live
    /// waveform. Called on the audio queue.
    var onLevel: (@Sendable (Float) -> Void)?
    private var levelThrottle = 0
    /// Called when capture stops unexpectedly (interruption that can't resume, etc.)
    var onInterruption: (@Sendable (String) -> Void)?
    /// Called when audio capture recovers unattended after an interruption.
    var onResumed: (@Sendable () -> Void)?
    /// Low-frequency audio health snapshot for the diagnostics screen.
    var onDiagnostics: (@Sendable (AudioDiagnosticsSnapshot) -> Void)?
    /// Route, interruption, recovery and transport events, newest first in UI.
    var onEvent: (@Sendable (AudioDiagnosticEvent) -> Void)?

    private lazy var targetFormat: AVAudioFormat = .init(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioPipelineConstants.sampleRate),
        channels: 1,
        interleaved: true
    )!

    /// Constant on-disk format. Hardware may change from 48 kHz to a Bluetooth
    /// rate mid-recording; every tap is converted into this stable archive while
    /// the ASR path independently converts to 16 kHz Int16.
    private lazy var archiveFormat: AVAudioFormat = .init(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: false
    )!

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(bitrate: Int) throws {
        guard !running else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.microphoneDenied
        }

        let session = AVAudioSession.sharedInstance()
        // `.spokenAudio` keeps recording alive when the screen locks or the iPad
        // Smart Folio cover closes. Noise suppression and AGC are enabled on the
        // input node in installTapAndStart().
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        do {
            try session.setActive(true, options: [])
        } catch {
            throw Self.activationError(error)
        }
        #if canImport(UIKit)
            beginBackgroundAssertion()
        #endif
        do {
            encoder = try OpusStreamEncoder(bitrate: bitrate)
            let recordingsRoot = try LocalRecordingStorage.defaultRoot()
            let writer = try LocalRecordingWriter(root: recordingsRoot, format: archiveFormat)
            processingQueue.sync {
                recordingWriter = writer
                signalAnalyzer = AudioSignalAnalyzer()
                diagnostics = AudioDiagnosticsSnapshot()
            }
        } catch {
            processingQueue.sync {
                encoder = nil
                recordingWriter = nil
            }
            releaseAudioSession()
            throw error
        }

        installObservers()
        do {
            try installTapAndStart()
        } catch {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            processingQueue.sync {
                converter = nil
                archiveConverter = nil
                encoder = nil
                recordingWriter?.fail(error.localizedDescription)
                recordingWriter = nil
            }
            NotificationCenter.default.removeObserver(self)
            releaseAudioSession()
            throw error
        }
        running = true
        startStallWatchdog()
    }

    @discardableResult
    func stop() -> URL? {
        guard running else { return nil }
        running = false
        stallTimer?.cancel()
        stallTimer = nil
        SharedMicrophone.shared.end()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Tear down on the processing queue: tap callbacks already enqueued
        // still read converter/encoder, so nil-ing them from here would race.
        let manifestURL: URL? = processingQueue.sync {
            converter = nil
            archiveConverter = nil
            encoder = nil
            let url = recordingWriter?.finish()
            recordingWriter = nil
            return url
        }
        NotificationCenter.default.removeObserver(self)
        releaseAudioSession()
        log.info("capture stopped")
        return manifestURL
    }

    #if canImport(UIKit)
        /// Hold a background task assertion while recording.
        ///
        /// Background mode `audio` is what really keeps capture alive; this is
        /// the cushion for the window in which it does not — the seconds after
        /// the microphone is taken and before it comes back.
        ///
        /// `backgroundTask` is only ever touched here and in
        /// `releaseAudioSession()`, both on the main thread: capture is rebuilt
        /// on `controlQueue`, and UIApplication is not to be called from there.
        ///
        /// `ifRecording` is for the re-take after a rebuild — recording may have
        /// been stopped between the control queue asking and this running, and
        /// an assertion taken after `releaseAudioSession()` is never ended.
        private func beginBackgroundAssertion(ifRecording: Bool = false) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.beginBackgroundAssertion(ifRecording: ifRecording)
                }
                return
            }
            guard !ifRecording || running else { return }
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared
                .beginBackgroundTask(withName: "MossLive.AudioCapture") { [weak self] in
                    self?.backgroundAssertionExpired()
                }
        }

        /// iOS **terminates** an app that lets a background task expire without
        /// ending it — the expiration handler used to only write a log line.
        ///
        /// That is how a lesson ended for good the moment something else took
        /// the microphone: iOS keyboard dictation interrupts the audio session,
        /// the app is in the background with nothing keeping it awake, the
        /// assertion runs out ~30 s later and the app is killed rather than
        /// suspended. Killed, it loses the id of the server session that is
        /// still being held open for it, so the recording the student starts
        /// again is a second lesson instead of the rest of the first one — on
        /// 19 August that happened three times, taking 8 to 12 minutes of each
        /// hour with it. Ending the assertion turns that into a suspend the app
        /// can come back from.
        ///
        /// Nothing is re-taken here: the budget is spent, and asking again in
        /// the handler would only expire again. `installTapAndStart()` takes a
        /// fresh one once the microphone is actually delivering audio.
        private func backgroundAssertionExpired() {
            let expired = backgroundTask
            backgroundTask = .invalid
            guard expired != .invalid else { return }
            UIApplication.shared.endBackgroundTask(expired)
            log.warning("background capture task assertion expired")
            record(
                AudioDiagnosticEvent(
                    kind: .transport,
                    message: "Hintergrundzeit abgelaufen – die Aufnahme läuft weiter, sobald das "
                        + "Mikrofon wieder frei ist"
                )
            )
        }
    #endif

    /// Return the shared session to ordinary media playback after recording.
    ///
    /// AVAudioSession keeps its category and mode after deactivation. Leaving
    /// `.playAndRecord` behind made LessonAudioPlayer believe capture
    /// still owned the session, so it skipped its `.playback` setup and played
    /// an already well-normalized recording through the quieter communication
    /// path. Voice processing must be disabled while the engine is stopped
    /// before changing to an output-only category.
    private func releaseAudioSession() {
        #if canImport(UIKit)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        #endif
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default)
    }

    /// New (non-resumed) server session: packets restart at seq 0.
    func resetSequence() {
        processingQueue.async { [weak self] in
            self?.encoder?.resetSequence()
        }
    }

    /// Persist the server id in the local manifest as soon as the WebSocket
    /// handshake assigns it. This is what lets a later, explicitly requested
    /// high-quality upload find the correct safety recording.
    func attachServerSession(_ sessionId: String) {
        processingQueue.async { [weak self] in
            self?.recordingWriter?.setServerSessionId(sessionId)
        }
    }

    /// Transport failures are part of the same recording history as microphone
    /// interruptions, even though they originate in WebSocketClient.
    func recordExternalEvent(_ event: AudioDiagnosticEvent) {
        processingQueue.async { [weak self] in
            self?.record(event)
        }
    }

    /// (Re)builds the converter for the current hardware format, installs the
    /// tap, and starts the engine. Called at start and after route changes,
    /// where the hardware format may have changed (e.g. Bluetooth mic).
    private func installTapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // A plain input-node tap receives the largely unprocessed microphone
        // signal. Voice processing switches the I/O unit to Apple's
        // device-specific speech pipeline: noise suppression, AGC and echo
        // cancellation. This is the missing piece that `.default` mode alone
        // never enabled.
        do {
            if !input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(true)
            }
        } catch {
            throw CaptureError.voiceProcessingUnavailable(error.localizedDescription)
        }
        input.isVoiceProcessingBypassed = false
        input.isVoiceProcessingAGCEnabled = true
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw CaptureError.microphoneDenied
        }
        guard let archiveConverter = AVAudioConverter(from: hardwareFormat, to: archiveFormat) else {
            throw CaptureError.microphoneDenied
        }
        converter.sampleRateConverterQuality = .max
        archiveConverter.sampleRateConverterQuality = .max
        // Swap on the processing queue — handleTap reads this property there.
        processingQueue.sync {
            self.converter = converter
            self.archiveConverter = archiveConverter
            diagnostics.hardwareSampleRate = hardwareFormat.sampleRate
            diagnostics.hardwareChannels = Int(hardwareFormat.channelCount)
            diagnostics.route = Self.currentRouteDescription()
            diagnostics.voiceProcessing = input.isVoiceProcessingEnabled
            diagnostics.automaticGainControl = input.isVoiceProcessingAGCEnabled
        }

        // ~20 ms of hardware audio per tap callback keeps latency minimal.
        let tapFrames = AVAudioFrameCount(hardwareFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardwareFormat) { [weak self] buffer, _ in
            // AVAudioEngine owns `buffer` and may recycle it immediately after
            // this callback. Copy before crossing the callback boundary.
            guard let ownedBuffer = buffer.deepCopy() else {
                self?.processingQueue.async {
                    self?.recordLostBuffer("Audiobuffer konnte nicht kopiert werden")
                }
                return
            }
            // Anything else that wants the microphone listens in rather than
            // taking it: a second engine on this input node would end capture.
            SharedMicrophone.shared.publish(ownedBuffer)
            self?.processingQueue.async {
                self?.handleTap(buffer: ownedBuffer)
            }
        }
        engine.prepare()
        try engine.start()
        #if canImport(UIKit)
            // Capture is back, so take the cushion again if it expired while
            // the microphone was gone. (`start()` takes the first one itself,
            // before `running` is set.)
            beginBackgroundAssertion(ifRecording: true)
        #endif
        SharedMicrophone.shared.begin(format: hardwareFormat)
        processingQueue.async { [weak self] in
            self?.lastBufferAt = Date()
        }
        log.info("capture running: hw=\(hardwareFormat.sampleRate)Hz ch=\(hardwareFormat.channelCount)")
        log.info("capture processing: voice=\(input.isVoiceProcessingEnabled) agc=\(input.isVoiceProcessingAGCEnabled)")
    }

    // MARK: - Conversion

    private func handleTap(buffer: AVAudioPCMBuffer) {
        lastBufferAt = Date()
        if stallReported {
            stallReported = false
            backgroundWaitReported = false
            wantsRebuildOnForeground = false
            record(
                AudioDiagnosticEvent(
                    kind: .recovered,
                    message: "Mikrofon wieder frei; die Aufnahme läuft ohne Unterbrechung weiter"
                )
            )
            onResumed?()
        }
        guard let converter, let archiveConverter, let encoder else { return }

        if let archiveBuffer = convert(buffer, using: archiveConverter, to: archiveFormat) {
            do {
                try recordingWriter?.write(archiveBuffer)
            } catch {
                record(
                    AudioDiagnosticEvent(
                        kind: .lostAudio,
                        message: "Lokale Sicherheitsaufnahme konnte nicht geschrieben werden: \(error.localizedDescription)"
                    )
                )
            }
        } else {
            recordLostBuffer("48-kHz-Sicherheitskopie konnte nicht konvertiert werden")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData?[0]
        else {
            if let error { log.error("convert failed: \(error.localizedDescription)") }
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        publishDiagnostics(samples)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        do {
            for packet in try encoder.feed(samples, captureTsMs: nowMs) {
                onPacket?(packet)
            }
        } catch {
            log.error("encode failed: \(String(describing: error))")
        }
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if let error {
            log.error("archive convert failed: \(error.localizedDescription)")
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    /// Signal health and UI level, throttled to every third ~20 ms buffer.
    private func publishDiagnostics(_ samples: [Int16]) {
        let measurement = signalAnalyzer.consume(samples)
        levelThrottle += 1
        guard levelThrottle % 3 == 0 else { return }
        diagnostics.level = measurement.level
        diagnostics.rmsDBFS = measurement.rmsDBFS
        diagnostics.peakDBFS = measurement.peakDBFS
        diagnostics.noiseFloorDBFS = measurement.noiseFloorDBFS
        diagnostics.clippedSamplePercent = measurement.clippedSamplePercent
        diagnostics.capturedSeconds = recordingWriter?.manifest.durationSeconds ?? 0
        onLevel?(measurement.level)
        onDiagnostics?(diagnostics)
    }

    // MARK: - Interruptions / route changes

    private func installObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleMediaReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )
        #if canImport(UIKit)
            center.addObserver(
                self, selector: #selector(handleDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil
            )
            center.addObserver(
                self, selector: #selector(handleDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification, object: nil
            )
            isForeground = UIApplication.shared.applicationState == .active
        #endif
    }

    #if canImport(UIKit)
        @objc private func handleDidEnterBackground() {
            isForeground = false
        }

        /// Back in the foreground, so a rebuild is allowed again.
        ///
        /// This is where a recording that went silent behind iOS dictation is
        /// actually put back together — the one place iOS lets it happen.
        @objc private func handleDidBecomeActive() {
            isForeground = true
            guard running else { return }
            let stalled = processingQueue.sync { Date().timeIntervalSince(lastBufferAt) }
            guard wantsRebuildOnForeground || !engine.isRunning || stalled > Self.stallSeconds else {
                return
            }
            wantsRebuildOnForeground = false
            requestResume(reason: "app returned to the foreground")
        }
    #endif

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            log.warning("audio interruption began (call/Siri)")
            let now = Date()
            processingQueue.async { [weak self] in
                self?.interruptionStartedAt = now
                self?.diagnostics.interruptions += 1
                self?.record(
                    AudioDiagnosticEvent(
                        kind: .interruptionBegan,
                        message: "Audio-Unterbrechung begann (Anruf, Siri oder andere App)",
                        date: now
                    )
                )
            }
            // iOS sometimes never delivers .ended (e.g. declined call while
            // locked) — the retry loop below recovers regardless.
            scheduleResumeRetries()
        case .ended:
            // Always try to resume, even without .shouldResume: during class
            // the device is locked in a pocket — "tap to resume" is exactly
            // what the user cannot do.
            if isForeground {
                requestResume(reason: "interruption ended")
            } else {
                controlQueue.async { [weak self] in self?.continueInBackground() }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard running else { return }
        let reason = Self.routeChangeReason(note)
        let route = Self.currentRouteDescription()
        processingQueue.async { [weak self] in
            guard let self else { return }
            diagnostics.routeChanges += 1
            record(
                AudioDiagnosticEvent(
                    kind: .routeChanged,
                    message: "Audio-Route geändert (\(reason)): \(route)"
                )
            )
        }
        restartEngine(reason: "audio route changed")
    }

    @objc private func handleMediaReset(_ note: Notification) {
        guard running else { return }
        recordExternalEvent(
            AudioDiagnosticEvent(
                kind: .mediaServicesReset,
                message: "iOS-Audiodienste wurden zurückgesetzt"
            )
        )
        // Apple: after a media-services reset everything must be rebuilt,
        // including the session configuration.
        requestResume(reason: "media services reset")
    }

    private func restartEngine(reason: String) {
        controlQueue.async { [weak self] in
            guard let self, self.running else { return }
            log.info("restarting audio engine: \(reason)")
            engine.stop()
            do {
                try installTapAndStart()
            } catch {
                scheduleResumeRetries()
            }
        }
    }

    /// Rebuild capture, off both the main thread and the audio queue.
    ///
    /// Every resume runs on `controlQueue`, and never on `processingQueue`:
    /// `installTapAndStart()` waits on the audio queue to swap the converters,
    /// so a retry that started there deadlocked the queue that writes the
    /// recording. The recording then stopped for good at the first
    /// interruption — a phone call, Siri, iOS dictation — with the engine
    /// still reporting itself as running and nothing left to notice.
    private func requestResume(reason: String) {
        controlQueue.async { [weak self] in
            self?.attemptResume(reason: reason)
        }
    }

    /// Full resume: reactivate the session, rebuild the tap, start the engine.
    /// On failure, keeps retrying in the background instead of giving up.
    private func attemptResume(reason: String) {
        guard running else { return }
        #if DEBUG
            // The invariant this method depends on, checked where a crash is a
            // test failure rather than a lost lesson.
            dispatchPrecondition(condition: .notOnQueue(processingQueue))
        #endif
        log.info("resuming audio after: \(reason)")
        engine.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            // Must match start(): route changes and media-service resets can
            // rebuild the I/O unit, and installTapAndStart() then re-enables
            // voice processing before capture resumes.
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
            )
            try session.setActive(true, options: [])
            try installTapAndStart()
            log.info("audio resumed")
            let now = Date()
            processingQueue.async { [weak self] in
                guard let self else { return }
                let gap = interruptionStartedAt.map { now.timeIntervalSince($0) }
                interruptionStartedAt = nil
                record(
                    AudioDiagnosticEvent(
                        kind: .interruptionEnded,
                        message: gap.map { String(format: "Audio nach %.1f Sekunden fortgesetzt", $0) }
                            ?? "Audio fortgesetzt",
                        gapSeconds: gap,
                        date: now
                    )
                )
            }
            onResumed?()
        } catch {
            log.warning("audio resume failed (\(Self.describe(error))); retrying")
            recordFromAnyQueue(
                AudioDiagnosticEvent(
                    kind: .lostAudio,
                    message: "Aufnahme konnte nicht fortgesetzt werden: \(Self.describe(error))"
                )
            )
            scheduleResumeRetries()
        }
    }

    /// Pick a real interruption back up without rebuilding anything.
    ///
    /// A genuine interruption leaves the session deactivated and the engine
    /// stopped, so sitting still would be silence for as long as the app stays
    /// in the background. This is the most iOS will consider from there:
    /// reactivate the session that already exists and start the engine that is
    /// already configured. No `setCategory`, no new tap, no converters — that
    /// would be *starting* a recording, which is the thing that gets refused.
    ///
    /// One attempt, and no retry loop. If iOS says no, the recording is picked
    /// up the moment the app is opened.
    private func continueInBackground() {
        guard running, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            try engine.start()
            log.info("audio continued in the background after an interruption")
            recordFromAnyQueue(
                AudioDiagnosticEvent(
                    kind: .interruptionEnded,
                    message: "Aufnahme im Hintergrund fortgesetzt"
                )
            )
            onResumed?()
        } catch {
            wantsRebuildOnForeground = true
            log.warning("background continue refused: \(Self.describe(error))")
            recordFromAnyQueue(
                AudioDiagnosticEvent(
                    kind: .lostAudio,
                    message: "iOS ließ die Aufnahme im Hintergrund nicht fortsetzen "
                        + "(\(Self.describe(error))); sie wird beim Öffnen der App fortgesetzt"
                )
            )
        }
    }

    /// The OSStatus is the useful half of an audio-session error and the half
    /// `localizedDescription` throws away — 561145187 (`'!rec'`) and 560557684
    /// (`'!int'`) are the two that decide whether a recording can come back.
    ///
    /// Not private so the codes themselves are covered: they are the whole
    /// reason the background rule exists, and a typo in one would only ever
    /// show up as an unreadable diagnostic months later.
    static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        let name =
            switch code {
            case 561_145_187: "cannotStartRecording"
            case 560_557_684: "cannotInterruptOthers"
            case 561_017_449: "insufficientPriority"
            default: (error as NSError).domain
            }
        return "\(name) \(code)"
    }

    /// Retries every few seconds while recording is wanted and the engine is
    /// down (a phone call can hold the mic for minutes). Surfaces a banner
    /// only while retrying, so a locked device recovers unattended.
    private func scheduleResumeRetries(
        message: String = "Aufnahme unterbrochen (Anruf oder Siri), wird automatisch fortgesetzt…"
    ) {
        onInterruption?(message)
        controlQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running else { return }
            // An engine that reports itself as running but delivers nothing is
            // exactly the state the watchdog exists for, so do not skip it.
            let silent = processingQueue.sync { Date().timeIntervalSince(self.lastBufferAt) }
            guard !engine.isRunning || silent > Self.stallSeconds else { return }
            // Retrying in the background retries a refusal, every three seconds,
            // for as long as the student is dictating. Wait for the microphone
            // or for the app to be opened instead.
            guard mayRebuildCapture(silentFor: silent) else { return }
            attemptResume(reason: "retry")
        }
    }

    /// How long the microphone may deliver nothing before capture is rebuilt,
    /// and how long a rebuild is given before another one is attempted.
    private static let stallSeconds: TimeInterval = 4

    /// Whether capture may be torn down and built again right now.
    ///
    /// Only in the foreground. iOS refuses to *start* a recording from the
    /// background — `AVAudioSession.ErrorCode.cannotStartRecording`, OSStatus
    /// 561145187, `'!rec'`: "the app is not allowed to start recording, usually
    /// because it is starting a mixable recording from the background". Echo's
    /// session is mixable whether it asks to be or not, because `.duckOthers`
    /// implicitly sets `.mixWithOthers`.
    ///
    /// So a rebuild in the background does not restore the recording. It
    /// destroys the one that is still there: `attemptResume()` stops the
    /// engine, and iOS then refuses to let it start again until the app is
    /// foregrounded. That is the whole of the bug the student kept reporting —
    /// use iOS keyboard dictation in another app, and four seconds later the
    /// watchdog meant to save the lesson is what ended it. Waiting instead
    /// costs nothing: the engine is still running and still holds a live
    /// session, so when dictation gives the microphone back the tap simply
    /// starts being called again, with nothing to restart.
    ///
    /// If it does not come back on its own, `handleDidBecomeActive()` rebuilds
    /// the moment the app is opened — which is exactly what happens today, and
    /// the one path iOS actually permits.
    private func mayRebuildCapture(silentFor silence: TimeInterval) -> Bool {
        if isForeground { return true }
        wantsRebuildOnForeground = true
        if !backgroundWaitReported {
            backgroundWaitReported = true
            recordFromAnyQueue(
                AudioDiagnosticEvent(
                    kind: .lostAudio,
                    message: String(
                        format: "Mikrofon seit %.0f s von einer anderen App belegt; die Aufnahme "
                            + "wartet im Hintergrund darauf, es zurückzubekommen (iOS lässt sie "
                            + "dort nicht neu starten)",
                        silence
                    ),
                    gapSeconds: silence
                )
            )
        }
        return false
    }

    /// Notices a microphone that went quiet without saying so.
    ///
    /// iOS keyboard dictation, a Siri request or another app taking the input
    /// does not always arrive as an interruption that ends — the tap simply
    /// stops being called while `AVAudioEngine` still reports itself as
    /// running. Nothing then rebuilt capture, so a lesson ended silently at the
    /// moment the student dictated a message, an hour before they noticed.
    /// Buffers arrive every ~20 ms, in silence too: four seconds without one
    /// means the microphone is gone, not that the room is quiet.
    private func startStallWatchdog() {
        stallTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + Self.stallSeconds, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, running else { return }
            let now = Date()
            guard now.timeIntervalSince(lastBufferAt) > Self.stallSeconds,
                  now.timeIntervalSince(lastResumeAttemptAt) > Self.stallSeconds
            else { return }
            let silence = now.timeIntervalSince(lastBufferAt)
            lastResumeAttemptAt = now
            if !stallReported {
                stallReported = true
                record(
                    AudioDiagnosticEvent(
                        kind: .lostAudio,
                        message: String(
                            format: "Kein Mikrofonsignal seit %.0f s (Diktat oder andere App)", silence
                        )
                    )
                )
                onInterruption?(
                    "Mikrofon von einer anderen Funktion belegt (z. B. Diktat) – "
                        + "die Aufnahme läuft automatisch weiter…"
                )
            }
            // In the background the microphone going quiet is something to sit
            // out, not something to fix. Rebuilding capture there cannot work
            // and is not free: see `mayRebuildCapture`.
            guard mayRebuildCapture(silentFor: silence) else { return }
            requestResume(reason: String(format: "no audio for %.1fs", silence))
        }
        timer.resume()
        stallTimer = timer
    }

    private func recordLostBuffer(_ message: String) {
        diagnostics.lostBuffers += 1
        record(AudioDiagnosticEvent(kind: .lostAudio, message: message))
    }

    private func record(_ event: AudioDiagnosticEvent) {
        recordingWriter?.append(event)
        onEvent?(event)
    }

    /// `record` from a caller that is not on `processingQueue`. The manifest
    /// writer belongs to that queue, and the resume paths run on `controlQueue`.
    private func recordFromAnyQueue(_ event: AudioDiagnosticEvent) {
        processingQueue.async { [weak self] in
            self?.record(event)
        }
    }

    private static func currentRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        return inputs.isEmpty ? "Kein Eingang" : inputs.joined(separator: ", ")
    }

    private static func routeChangeReason(_ note: Notification) -> String {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return "unbekannt" }
        switch reason {
        case .newDeviceAvailable: return "neues Gerät"
        case .oldDeviceUnavailable: return "Gerät getrennt"
        case .categoryChange: return "Audio-Kategorie"
        case .override: return "manuelle Route"
        case .wakeFromSleep: return "Gerät aufgeweckt"
        case .noSuitableRouteForCategory: return "keine geeignete Route"
        case .routeConfigurationChange: return "Konfiguration"
        case .unknown: return "unbekannt"
        @unknown default: return "unbekannt"
        }
    }
}
