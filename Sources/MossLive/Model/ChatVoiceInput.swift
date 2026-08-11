import AVFoundation
import Foundation
import Observation
import Speech

/// Live dictation for the chat composer. Recognition uses Apple's speech
/// service directly; the captured audio is never uploaded to Echo's server.
@MainActor
@Observable
final class ChatVoiceInput {
    private(set) var isRecording = false
    private(set) var transcript = ""
    var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInputTap = false

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        guard await requestSpeechPermission() else {
            errorMessage = "Spracherkennung ist nicht erlaubt. Du kannst sie in den iOS-Einstellungen aktivieren."
            return
        }
        guard await requestMicrophonePermission() else {
            errorMessage = "Mikrofonzugriff ist nicht erlaubt. Du kannst ihn in den iOS-Einstellungen aktivieren."
            return
        }
        guard recognizer?.isAvailable == true,
              recognizer?.supportsOnDeviceRecognition == true
        else {
            errorMessage = "Die lokale Spracherkennung ist auf diesem Gerät gerade nicht verfügbar."
            return
        }

        cleanup()
        transcript = ""
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        request = recognitionRequest

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            hasInputTap = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.stop() }
                    }
                    if let error, self.isRecording {
                        self.errorMessage = error.localizedDescription
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Diktat konnte nicht gestartet werden: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stop() {
        guard isRecording || task != nil || hasInputTap else { return }
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
