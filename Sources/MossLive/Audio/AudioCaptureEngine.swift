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
/// Session config: `.voiceChat` + AVAudioEngine voice processing applies
/// Apple's device-tuned noise suppression and automatic gain control;
/// `.playAndRecord` + background mode `audio` keeps capture alive when the
/// app is backgrounded or when the iPad lid is closed.
final class AudioCaptureEngine {
    /// Recording is intentionally nonmixable. `.duckOthers` used to make the
    /// session mixable implicitly, which iOS refuses to reactivate for input
    /// from the background (`cannotStartRecording`). Echo has no playback to
    /// duck, so that option was both semantically wrong and the source of the
    /// failed hand-off to keyboard dictation.
    static let captureSessionMode: AVAudioSession.Mode = .voiceChat
    static let captureSessionOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP,
        .defaultToSpeaker,
        .overrideMutedMicrophoneInterruption,
    ]

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
    /// Recovery state. Mutated on `controlQueue`; notification handlers only
    /// enqueue transitions onto that queue.
    private var isForeground = true
    private var wantsRebuildOnForeground = false
    private var audioSessionInactive = false
    /// So the "waiting in the background" note is written once per outage
    /// rather than every two seconds for as long as dictation is open.
    private var backgroundWaitReported = false
    /// Avoid repeating the same refusal in diagnostics if iOS emits more than
    /// one end/route signal for an outage.
    private var lastResumeFailure: String?
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
        // `.voiceChat` matches the Voice Processing I/O unit enabled below.
        // `overrideMutedMicrophoneInterruption` is the supported way to survive
        // a Smart Folio mute; `.spokenAudio` is a playback mode for podcasts.
        try session.setCategory(
            .playAndRecord,
            mode: Self.captureSessionMode,
            options: Self.captureSessionOptions
        )
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        do {
            try session.setActive(true, options: [])
        } catch {
            throw Self.activationError(error)
        }
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
        controlQueue.async { [weak self] in
            self?.audioSessionInactive = false
            self?.wantsRebuildOnForeground = false
            self?.backgroundWaitReported = false
            self?.lastResumeFailure = nil
        }
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
        /// Hold a short background assertion while an interruption has removed
        /// the audio background-mode assertion.
        ///
        /// Starting this with the recording wasted the entire allowance long
        /// before dictation was used. It now starts only when the audio session
        /// becomes inactive and ends as soon as capture resumes.
        ///
        /// Every access to `backgroundTask` stays on the main thread; capture
        /// recovery itself runs on `controlQueue`.
        private func beginBackgroundAssertion() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.beginBackgroundAssertion()
                }
                return
            }
            guard running else { return }
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared
                .beginBackgroundTask(withName: "MossLive.AudioCapture") { [weak self] in
                    self?.backgroundAssertionExpired()
                }
        }

        private func endBackgroundAssertion() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.endBackgroundAssertion() }
                return
            }
            let task = backgroundTask
            backgroundTask = .invalid
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
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
        /// the handler would only expire again. A later interruption gets a new
        /// assertion after capture has genuinely resumed in between.
        private func backgroundAssertionExpired() {
            let expired = backgroundTask
            backgroundTask = .invalid
            guard expired != .invalid else { return }
            UIApplication.shared.endBackgroundTask(expired)
            log.warning("background capture task assertion expired")
            recordFromAnyQueue(
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
            endBackgroundAssertion()
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
            // Audio background mode owns execution again; the temporary
            // interruption cushion is no longer needed.
            endBackgroundAssertion()
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
            controlQueue.async { [weak self] in
                self?.backgroundWaitReported = false
                self?.audioSessionInactive = false
                self?.wantsRebuildOnForeground = false
                self?.lastResumeFailure = nil
            }
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
            let foreground = UIApplication.shared.applicationState == .active
            controlQueue.async { [weak self] in self?.isForeground = foreground }
        #endif
    }

    #if canImport(UIKit)
        @objc private func handleDidEnterBackground() {
            controlQueue.async { [weak self] in self?.isForeground = false }
        }

        /// Back in the foreground, so a rebuild is allowed again.
        ///
        /// This is where a recording that went silent behind iOS dictation is
        /// actually put back together — the one place iOS lets it happen.
        @objc private func handleDidBecomeActive() {
            controlQueue.async { [weak self] in
                guard let self else { return }
                isForeground = true
                guard running else { return }
                let stalled = processingQueue.sync { Date().timeIntervalSince(self.lastBufferAt) }
                guard wantsRebuildOnForeground || !engine.isRunning || stalled > Self.stallSeconds else {
                    return
                }
                wantsRebuildOnForeground = false
                attemptResume(reason: "app returned to the foreground")
            }
        }
    #endif

    /// Pause the configured engine as soon as iOS takes the session. This
    /// releases its I/O for keyboard dictation's first tap while preserving the
    /// tap and converters for a true resume when the interruption ends.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            #if canImport(UIKit)
                beginBackgroundAssertion()
            #endif
            let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt
            controlQueue.async { [weak self] in
                guard let self, running else { return }
                audioSessionInactive = true
                wantsRebuildOnForeground = true
                engine.pause()
                log.warning("audio session interrupted (reason: \(String(describing: rawReason)))")
                let now = Date()
                processingQueue.async { [weak self] in
                    guard let self else { return }
                    interruptionStartedAt = now
                    diagnostics.interruptions += 1
                    record(
                        AudioDiagnosticEvent(
                            kind: .interruptionBegan,
                            message: "Mikrofon an Diktat, Siri, einen Anruf oder eine andere App übergeben",
                            date: now
                        )
                    )
                }
                onInterruption?(
                    "Mikrofon wird vorübergehend von einer anderen Funktion verwendet – "
                        + "Echo setzt die Aufnahme danach automatisch fort…"
                )
            }
        case .ended:
            // A lesson recording is an explicit, continuing user action, so it
            // is appropriate to resume even if shouldResume is absent. This
            // runs only after iOS says the competing session has ended.
            controlQueue.async { [weak self] in
                guard let self, running else { return }
                resumeConfiguredEngine(reason: "audio interruption ended")
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
            // A route change in the background used to come straight through
            // here and stop the engine — the same fatal teardown the watchdog
            // was stopped from doing, by a different door. Dictation taking and
            // returning the microphone *is* a route change.
            guard isForeground else {
                log.info("route changed in the background (\(reason)); trying configured resume")
                wantsRebuildOnForeground = true
                if audioSessionInactive {
                    resumeConfiguredEngine(reason: reason)
                }
                return
            }
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
                mode: Self.captureSessionMode,
                options: Self.captureSessionOptions
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
            // A full rebuild is a foreground-only move. In the background,
            // wait for the interruption-end or return-route signal instead of
            // activating recording while another app still owns the microphone.
            guard isForeground else {
                wantsRebuildOnForeground = true
                return
            }
            attemptResume(reason: "retry")
        }
    }

    /// How long the microphone may deliver nothing before capture is rebuilt,
    /// and how long a rebuild is given before another one is attempted.
    private static let stallSeconds: TimeInterval = 4

    /// Resume the engine only after iOS says the competing audio session has
    /// ended. The tap, converters, category, and voice-processing unit remain
    /// configured throughout the interruption; this is a resume, not a new
    /// background recording.
    private func resumeConfiguredEngine(reason: String) {
        guard running else { return }
        log.info("resuming configured audio engine after: \(reason)")
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            audioSessionInactive = false
            wantsRebuildOnForeground = false
            lastResumeFailure = nil
            #if canImport(UIKit)
                endBackgroundAssertion()
            #endif
            log.info("microphone resumed")
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
            wantsRebuildOnForeground = true
            let described = Self.describe(error)
            guard lastResumeFailure != described else { return }
            lastResumeFailure = described
            log.warning("recommended audio resume failed: \(described)")
            recordFromAnyQueue(
                AudioDiagnosticEvent(
                    kind: .lostAudio,
                    message: "iOS konnte das Mikrofon im Hintergrund nicht fortsetzen (\(described)); "
                        + "die Aufnahme wird beim Öffnen der App fortgesetzt"
                )
            )
        }
    }

    /// The "waiting in the background" note, written once per outage rather
    /// than every two seconds for as long as dictation is open.
    private func noteBackgroundWait(silentFor silence: TimeInterval) {
        wantsRebuildOnForeground = true
        guard !backgroundWaitReported else { return }
        backgroundWaitReported = true
        recordFromAnyQueue(
            AudioDiagnosticEvent(
                kind: .lostAudio,
                message: String(
                    format: "Mikrofon seit %.0f s von einer anderen App belegt (z. B. Diktat); "
                        + "Echo wartet auf die Freigabe durch iOS",
                    silence
                ),
                gapSeconds: silence
            )
        )
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
            guard now.timeIntervalSince(lastBufferAt) > Self.stallSeconds else { return }
            let silence = now.timeIntervalSince(lastBufferAt)
            // A rebuild is expensive and is rate-limited. Background recovery
            // is driven by AVAudioSession interruption and route notifications.
            let mayRebuild = now.timeIntervalSince(lastResumeAttemptAt) > Self.stallSeconds
            if mayRebuild { lastResumeAttemptAt = now }
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
            controlQueue.async { [weak self] in
                guard let self, running else { return }
                guard isForeground else {
                    noteBackgroundWait(silentFor: silence)
                    return
                }
                guard mayRebuild else { return }
                attemptResume(reason: String(format: "no audio for %.1fs", silence))
            }
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
