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
/// Session config: `.default` mode keeps iOS input processing (AGC!) enabled
/// so distant classroom speech is captured at a usable level;
/// `.playAndRecord` + background mode `audio` keeps capture alive when the
/// app is backgrounded (within iOS limits).
final class AudioCaptureEngine {
    enum CaptureError: LocalizedError {
        case microphoneDenied
        case audioSessionBusy

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Mikrofonzugriff verweigert. In den iOS-Einstellungen unter Datenschutz > Mikrofon erlauben."
            case .audioSessionBusy:
                "Mikrofon wird von einer anderen App belegt (z. B. ein Discord- oder Telefon-Anruf). "
                    + "Bitte diese App schließen oder den Anruf beenden und erneut starten."
            }
        }
    }

    /// Which session mode the capture runs in.
    ///
    /// `.measurement` is the one Apple documents as minimising input signal
    /// processing — no AGC, no shaping — which is exactly what a recording of a
    /// room wants and exactly what `SpeechGatedGain` then levels. `.default`
    /// leaves Apple's processing in charge and is what this app used to do.
    ///
    /// The category stays `.playAndRecord` either way. `.record` would be the
    /// stricter choice, but it silences other audio outright, and playing
    /// something in another app while recording is how this gets tested.
    private static func mode(cleanCapture: Bool) -> AVAudioSession.Mode {
        cleanCapture ? .measurement : .default
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
    /// Which gain does the levelling: ours, or the one built into iOS.
    ///
    /// Measured against Voice Memos on the same iPad in the same room, iOS's
    /// costs 16 dB between speech and the room. Kept as a switch rather than a
    /// straight replacement because the AGC is also what lifts a teacher eight
    /// metres away, and no measurement here can settle what that does to a real
    /// lesson — one lesson each way can.
    private var cleanCapture = true
    private var gain: SpeechGatedGain?

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

    func start(bitrate: Int, cleanCapture: Bool = true, maxGainDb: Double = 24) throws {
        guard !running else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.microphoneDenied
        }
        self.cleanCapture = cleanCapture
        var settings = SpeechGatedGain.Settings()
        settings.maxGainDb = maxGainDb
        let stage = cleanCapture ? SpeechGatedGain(settings: settings) : nil
        processingQueue.sync { self.gain = stage }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: Self.mode(cleanCapture: cleanCapture),
                                options: [.allowBluetooth, .duckOthers])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        do {
            try session.setActive(true, options: [])
        } catch {
            throw Self.activationError(error)
        }
        // Only where the route actually has a settable gain — most built-in
        // ones do not, and asking anyway is how you end up believing a line
        // that never ran.
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }

        encoder = try OpusStreamEncoder(bitrate: bitrate)

        installObservers()
        try installTapAndStart()
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
            gain = nil
        }
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("capture stopped")
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

        let captured = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        // Levelled before anything else sees it, so the stream, the recording
        // and the meter all agree on what was heard.
        let samples = gain?.process(captured, sampleRate: AudioPipelineConstants.sampleRate) ?? captured
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
            // Must match start(), or a recording resumed after a phone call
            // comes back levelled by a different stage than it began with.
            try session.setCategory(.playAndRecord, mode: Self.mode(cleanCapture: cleanCapture),
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
