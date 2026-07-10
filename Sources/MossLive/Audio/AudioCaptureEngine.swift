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
/// Session config: `.measurement` mode disables system voice processing for
/// the lowest capture latency; `.playAndRecord` + background mode `audio`
/// keeps capture alive when the app is backgrounded (within iOS limits).
final class AudioCaptureEngine {
    enum CaptureError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone access is denied. Enable it in Settings > Privacy > Microphone."
            }
        }
    }

    private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "audio")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var encoder: OpusStreamEncoder?
    private let processingQueue = DispatchQueue(label: "com.fourmbs.mosslive.audio", qos: .userInitiated)
    private(set) var running = false

    /// Called for every encoded packet (already framed for the wire by the caller).
    var onPacket: (@Sendable (OpusStreamEncoder.Packet) -> Void)?
    /// Called when capture stops unexpectedly (interruption that can't resume, etc.)
    var onInterruption: (@Sendable (String) -> Void)?

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
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetooth, .duckOthers])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])

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
        converter = nil
        encoder = nil
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
        self.converter = converter

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

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        do {
            for packet in try encoder.feed(samples, captureTsMs: nowMs) {
                onPacket?(packet)
            }
        } catch {
            log.error("encode failed: \(String(describing: error))")
        }
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
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                restartEngine(reason: "interruption ended")
            } else {
                onInterruption?("Recording was interrupted (phone call or Siri). Tap record to resume.")
            }
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
        onInterruption?("The system audio service restarted. Tap record to resume.")
    }

    private func restartEngine(reason: String) {
        guard running else { return }
        log.info("restarting audio engine: \(reason)")
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            onInterruption?("Could not restart the microphone: \(error.localizedDescription)")
        }
    }
}
