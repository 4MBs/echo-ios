import AVFoundation
import Foundation

/// The one microphone, while a lesson recording owns it.
///
/// iOS has a single audio input, and an app that takes it twice loses it:
/// chat dictation used to reconfigure the shared session (`.record`,
/// `.measurement`) and start a second `AVAudioEngine` on the same input node,
/// then deactivate the session when it was done — each of which ends the
/// lesson recording the student left running, minutes of a class with it.
///
/// So dictation no longer takes the microphone while a recording holds it. The
/// capture engine publishes every buffer it receives here, and anything else
/// that needs the microphone listens in.
final class SharedMicrophone: @unchecked Sendable {
    static let shared = SharedMicrophone()

    private let lock = NSLock()
    private var listeners: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private var captureFormat: AVAudioFormat?

    /// The format capture is running in, or nil when nobody is recording.
    var format: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return captureFormat
    }

    /// Whether a lesson recording currently owns the microphone.
    var isCapturing: Bool { format != nil }

    func begin(format: AVAudioFormat) {
        lock.lock()
        captureFormat = format
        lock.unlock()
    }

    func end() {
        lock.lock()
        captureFormat = nil
        lock.unlock()
    }

    /// Called on the audio tap's thread — listeners must return immediately.
    func publish(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = Array(listeners.values)
        lock.unlock()
        for listener in current {
            listener(buffer)
        }
    }

    func addListener(_ listener: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = listener
        lock.unlock()
        return id
    }

    func removeListener(_ id: UUID) {
        lock.lock()
        listeners.removeValue(forKey: id)
        lock.unlock()
    }
}
