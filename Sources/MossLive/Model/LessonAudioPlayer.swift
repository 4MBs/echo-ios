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

    /// Playback speed. A lesson is someone talking, and talking is the one
    /// thing that survives being sped up — so the control belongs on the
    /// player rather than in a menu three taps away.
    private(set) var rate: Double = 1

    /// The offered speeds. Below 1 is missing on purpose: a recording of a
    /// classroom is already slower than reading it.
    static let rates: [Double] = [1, 1.25, 1.5, 2]

    /// Which transcript line the playhead is inside.
    ///
    /// Kept as its own property rather than worked out from `currentTime` on
    /// demand, because the two change at wildly different rates: `currentTime`
    /// moves seven times a second, and a spoken line lasts seconds. A view that
    /// asked the clock had to be rebuilt on every tick — for the transcript,
    /// that meant re-laying out several hundred lines to move one highlight.
    /// Observation is per-property, so reading this instead costs a redraw when
    /// the line changes and nothing in between.
    private(set) var activeIndex: Int?

    /// The transcript the playhead is tracked against, set once per lesson.
    @ObservationIgnored private var segments: [TranscriptSegment] = []

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
            // Must be set before prepareToPlay, or the rate is ignored for
            // the whole life of this player.
            player.enableRate = true
            player.rate = Float(rate)
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

    /// Move the playhead without deciding whether to play: scrubbing a paused
    /// recording should leave it paused, and scrubbing a playing one should not
    /// interrupt it.
    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = clamp(time, player)
        currentTime = player.currentTime
        refreshActiveIndex()
    }

    /// Change speed without disturbing playback: AVAudioPlayer applies a new
    /// rate to a running player, and remembers it for the next `play()`.
    func setRate(_ value: Double) {
        rate = value
        player?.rate = Float(value)
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
        // Deactivating the session while the capture engine holds it would
        // stop a running recording; only release what this player activated.
        let session = AVAudioSession.sharedInstance()
        if configuredSession, session.category != .playAndRecord {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        configuredSession = false
    }

    /// Hand the player the transcript it is playing, so it can say which line
    /// is being spoken. Called once, when the lesson's segments arrive.
    func track(_ segments: [TranscriptSegment]) {
        self.segments = segments
        refreshActiveIndex()
    }

    /// Recompute the spoken line, and publish it only when it actually moved.
    /// Assigning an equal value would still notify — Observation does not
    /// compare — and that is exactly the redraw this is here to avoid.
    private func refreshActiveIndex() {
        let index = segmentIndex(at: currentTime)
        if index != activeIndex { activeIndex = index }
    }

    private func segmentIndex(at time: Double) -> Int? {
        guard isPlaying || time > 0 else { return nil }
        // Playback almost always sits in the line it was in, or the next one.
        // Only a seek needs the full scan.
        if let active = activeIndex, segments.indices.contains(active) {
            if time >= segments[active].t0, time < segments[active].t1 { return active }
            let next = active + 1
            if segments.indices.contains(next),
               time >= segments[next].t0, time < segments[next].t1 {
                return next
            }
        }
        return segments.firstIndex { time >= $0.t0 && time < $0.t1 }
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
