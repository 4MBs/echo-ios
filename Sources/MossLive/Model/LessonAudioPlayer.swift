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

    /// Which transcript line the playhead is inside, published only when it
    /// actually changes.
    ///
    /// This used to be asked of the player from inside the transcript's `body`
    /// — which made the whole transcript a reader of `currentTime`, and
    /// `currentTime` moves seven times a second. Hundreds of lines were
    /// rebuilt for a highlight that steps once every few seconds. The player
    /// tracks the boundary itself now, and the view observes only this.
    private(set) var activeIndex: Int?

    @ObservationIgnored private var spans: [(start: Double, end: Double)] = []

    @ObservationIgnored private let log = Logger(subsystem: "com.fourmbs.mosslive", category: "audio-playback")
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Whether this player configured the audio session itself (it must never
    /// touch the session while the capture engine owns it — see below).
    @ObservationIgnored private var configuredSession = false

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
            // While a live recording runs, the capture engine owns the shared
            // session (.playAndRecord — which already permits playback).
            // Reconfiguring it here would cut off the microphone mid-lesson.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                configuredSession = true
            }
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            loadedLessonId = lessonId
            return true
        } catch {
            log.warning("audio load failed: \(error.localizedDescription)")
            errorMessage = "Audio nicht verfügbar: \(error.localizedDescription)"
            return false
        }
    }

    func playFrom(_ time: Double) {
        guard let player else { return }
        player.currentTime = clamp(time, player)
        player.play()
        isPlaying = true
        currentTime = player.currentTime
        refreshActiveIndex()
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
        activeIndex = nil
        ticker?.cancel()
        ticker = nil
        // Deactivating the session while the capture engine holds it would
        // stop a running recording; only release what this player activated.
        let session = AVAudioSession.sharedInstance()
        if configuredSession, session.category != .playAndRecord {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        configuredSession = false
    }

    /// Hand the player the lines it is playing, once, when they load.
    func track(_ segments: [TranscriptSegment]) {
        spans = segments.map { (start: $0.t0, end: $0.t1) }
        refreshActiveIndex()
    }

    /// Cheap in the common case: the playhead is still inside the line it was
    /// in a tick ago, so the answer is the one already published.
    private func refreshActiveIndex() {
        guard !spans.isEmpty, isPlaying || currentTime > 0 else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        if let current = activeIndex, spans.indices.contains(current),
           currentTime >= spans[current].start, currentTime < spans[current].end {
            return
        }
        let found = spans.firstIndex { currentTime >= $0.start && currentTime < $0.end }
        if found != activeIndex { activeIndex = found }
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
                    self.activeIndex = nil
                    return
                }
                self.refreshActiveIndex()
            }
        }
    }
}
