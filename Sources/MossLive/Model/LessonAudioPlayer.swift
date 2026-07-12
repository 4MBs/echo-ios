import AVFoundation
import os
import SwiftUI

/// Plays a lesson recording downloaded from the server and lets the transcript
/// seek it. One instance per open lesson; downloads lazily on the first play.
///
/// End-of-playback is detected by the polling ticker (not an AVAudioPlayer
/// delegate), which keeps this a plain @Observable value with no @objc surface.
@MainActor
@Observable
final class LessonAudioPlayer {
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var loadedLessonId: String?
    var errorMessage: String?

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "audio-playback")
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// True once the recording is downloaded and ready to seek/play.
    var isReady: Bool { player != nil }

    /// Download + prepare the recording if not already loaded. Safe to call
    /// repeatedly. Returns true when the player is ready.
    @discardableResult
    func ensureLoaded(api: BackendAPI, lessonId: String) async -> Bool {
        if loadedLessonId == lessonId, player != nil { return true }
        guard !isLoading else { return player != nil }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fileURL = try await api.downloadAudio(id: lessonId)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            loadedLessonId = lessonId
            return true
        } catch {
            log.warning("audio load failed: \(error.localizedDescription)")
            errorMessage = "Audio unavailable: \(error.localizedDescription)"
            return false
        }
    }

    func playFrom(_ time: Double) {
        guard let player else { return }
        player.currentTime = clamp(time, player)
        player.play()
        isPlaying = true
        currentTime = player.currentTime
        startTicker()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Index of the segment covering the playhead, for highlighting.
    func activeSegmentIndex(in segments: [TranscriptSegment]) -> Int? {
        guard isPlaying || currentTime > 0 else { return nil }
        return segments.firstIndex { currentTime >= $0.t0 && currentTime < $0.t1 }
    }

    private func clamp(_ time: Double, _ player: AVAudioPlayer) -> Double {
        max(0, min(time, max(0, player.duration - 0.05)))
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying, self.isPlaying {
                    // finished (or was paused elsewhere): reset to the start
                    self.isPlaying = false
                    self.currentTime = 0
                    return
                }
            }
        }
    }
}
