import AVFoundation
import Foundation
import os

/// Microphone capture -> 16 kHz mono Int16 -> Opus packets.
///
/// Uses AVAudioEngine with a tap on the input node in the hardware format,
/// converts with AVAudioConverter, and hands ~20 ms Opus packets to `onPacket`
/// (called on the audio conversion queue — the consumer must be fast and
/// non-blocking; WebSocketClient.sendAudioFrame is).
///
/// Session config: `.videoChat` + AVAudioEngine voice processing applies
/// Apple's device-tuned noise suppression and automatic gain control;
/// `.playAndRecord` + background mode `audio` keeps capture alive when the
/// app is backgrounded (within iOS limits).
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
    private var encoder: OpusStreamEncoder?
    private let processingQueue = DispatchQueue(label: "com.fourmbs.mosslive.audio", qos: .userInitiated)
    private(set) var running = false

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

    private lazy var targetFormat: AVAudioFormat = .init(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioPipelineConstants.sampleRate),
        channels: 1,
        interleaved: true
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
        // The session mode selects voice-appropriate routing and EQ. The actual
        // noise suppression and AGC are enabled explicitly on the input node in
        // installTapAndStart(); selecting a mode alone does not turn them on.
        try session.setCategory(.playAndRecord, mode: .videoChat,
                                options: [.allowBluetooth, .duckOthers])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        do {
            try session.setActive(true, options: [])
        } catch {
            throw Self.activationError(error)
        }
        encoder = try OpusStreamEncoder(bitrate: bitrate)

        installObservers()
        do {
            try installTapAndStart()
        } catch {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            processingQueue.sync {
                converter = nil
                encoder = nil
            }
            NotificationCenter.default.removeObserver(self)
            releaseAudioSession()
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Tear down on the processing queue: tap callbacks already enqueued
        // still read converter/encoder, so nil-ing them from here would race.
        processingQueue.sync {
            converter = nil
            encoder = nil
        }
        NotificationCenter.default.removeObserver(self)
        releaseAudioSession()
        log.info("capture stopped")
    }

    /// Return the shared session to ordinary media playback after recording.
    ///
    /// AVAudioSession keeps its category and mode after deactivation. Leaving
    /// `.playAndRecord/.videoChat` behind made LessonAudioPlayer believe capture
    /// still owned the session, so it skipped its `.playback` setup and played
    /// an already well-normalized recording through the quieter communication
    /// path. Voice processing must be disabled while the engine is stopped
    /// before changing to an output-only category.
    private func releaseAudioSession() {
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
        converter.sampleRateConverterQuality = .max
        // Swap on the processing queue — handleTap reads this property there.
        processingQueue.sync { self.converter = converter }

        // ~20 ms of hardware audio per tap callback keeps latency minimal.
        let tapFrames = AVAudioFrameCount(hardwareFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.handleTap(buffer: buffer)
            }
        }
        engine.prepare()
        try engine.start()
        log.info("capture running: hw=\(hardwareFormat.sampleRate)Hz ch=\(hardwareFormat.channelCount)")
        log.info("capture processing: voice=\(input.isVoiceProcessingEnabled) agc=\(input.isVoiceProcessingAGCEnabled)")
    }

    // MARK: - Conversion

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let converter, let encoder else { return }
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
        publishLevel(samples)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        do {
            for packet in try encoder.feed(samples, captureTsMs: nowMs) {
                onPacket?(packet)
            }
        } catch {
            log.error("encode failed: \(String(describing: error))")
        }
    }

    /// RMS of the buffer mapped to 0...1 with a speech-friendly curve, every
    /// third ~20 ms buffer (so the UI gets ~16 values/second).
    private func publishLevel(_ samples: [Int16]) {
        levelThrottle += 1
        guard levelThrottle % 3 == 0, let onLevel, !samples.isEmpty else { return }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        // Map ~[-50 dB, -8 dB] onto 0...1 so normal speech uses the range.
        let db = 20 * log10(max(rms, 1e-6))
        let level = Float(min(max((db + 50) / 42, 0), 1))
        onLevel(level)
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
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            log.warning("audio interruption began (call/Siri)")
            // iOS sometimes never delivers .ended (e.g. declined call while
            // locked) — the retry loop below recovers regardless.
            scheduleResumeRetries()
        case .ended:
            // Always try to resume, even without .shouldResume: during class
            // the device is locked in a pocket — "tap to resume" is exactly
            // what the user cannot do.
            attemptResume(reason: "interruption ended")
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard running else { return }
        restartEngine(reason: "audio route changed")
    }

    @objc private func handleMediaReset(_ note: Notification) {
        guard running else { return }
        // Apple: after a media-services reset everything must be rebuilt,
        // including the session configuration.
        attemptResume(reason: "media services reset")
    }

    private func restartEngine(reason: String) {
        guard running else { return }
        log.info("restarting audio engine: \(reason)")
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            scheduleResumeRetries()
        }
    }

    /// Full resume: reactivate the session, rebuild the tap, start the engine.
    /// On failure, keeps retrying in the background instead of giving up.
    private func attemptResume(reason: String) {
        guard running else { return }
        log.info("resuming audio after: \(reason)")
        engine.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            // Must match start(): route changes and media-service resets can
            // rebuild the I/O unit, and installTapAndStart() then re-enables
            // voice processing before capture resumes.
            try session.setCategory(.playAndRecord, mode: .videoChat,
                                    options: [.allowBluetooth, .duckOthers])
            try session.setActive(true, options: [])
            try installTapAndStart()
            log.info("audio resumed")
            onResumed?()
        } catch {
            log.warning("audio resume failed (\(error.localizedDescription)); retrying")
            scheduleResumeRetries()
        }
    }

    /// Retries every few seconds while recording is wanted and the engine is
    /// down (a phone call can hold the mic for minutes). Surfaces a banner
    /// only while retrying, so a locked device recovers unattended.
    private func scheduleResumeRetries() {
        onInterruption?("Aufnahme unterbrochen (Anruf oder Siri), wird automatisch fortgesetzt…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running, !self.engine.isRunning else { return }
            self.attemptResume(reason: "retry")
        }
    }
}
