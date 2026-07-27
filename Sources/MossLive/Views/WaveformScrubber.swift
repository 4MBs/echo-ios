import SwiftUI

/// The recording, drawn as its own waveform and draggable.
///
/// A progress bar says how far through you are and nothing about what you are
/// scrubbing through. A waveform shows where the talking is, so the silence
/// before the lesson starts and the gap where the class worked on their own are
/// visible rather than something you hunt for by dragging.
///
/// Drawn in a `Canvas` rather than as a stack of shapes: this redraws on every
/// frame of a drag, and several hundred `Capsule` views would each want layout.
struct WaveformScrubber: View {
    let peaks: [Double]
    /// How far through the recording is, 0…1.
    let progress: Double
    /// Called with a fraction of the whole while the finger is down.
    let onScrub: (Double) -> Void

    /// Bars are ~3.5pt apart, which is dense enough to read as a waveform and
    /// coarse enough that a 45-minute lesson does not become a grey block.
    private static let barSpacing: CGFloat = 3.5
    private static let minimumBars = 24

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let bars = downsampled(to: geo.size.width)
            Canvas { context, size in
                guard !bars.isEmpty else { return }
                let slot = size.width / CGFloat(bars.count)
                let width = max(1.2, slot - 1.3)
                let playedUntil = size.width * CGFloat(min(max(progress, 0), 1))
                for (index, peak) in bars.enumerated() {
                    let x = CGFloat(index) * slot
                    // A floor, so silence is still a line rather than a gap —
                    // the bar count is the time axis and it must not have holes.
                    let height = max(2, CGFloat(peak) * size.height)
                    let bar = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: width,
                        height: height
                    )
                    let played = x + slot / 2 <= playedUntil
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: width / 2),
                        with: .color(played ? Theme.accent : Color(.tertiaryLabel))
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        guard geo.size.width > 0 else { return }
                        onScrub(min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(isDragging ? nil : .linear(duration: 0.15), value: progress)
        }
        .frame(height: 38)
        .accessibilityElement()
        .accessibilityLabel("Aufnahme")
        .accessibilityValue("\(Int((progress * 100).rounded())) Prozent")
    }

    /// One bar per ~3.5pt, each the loudest moment it covers. Taking the peak
    /// rather than the mean keeps a short sharp sound visible instead of
    /// averaging it away into the quiet around it.
    private func downsampled(to width: CGFloat) -> [Double] {
        let target = max(Self.minimumBars, Int(width / Self.barSpacing))
        guard peaks.count > target, target > 0 else { return peaks }
        let bucket = Double(peaks.count) / Double(target)
        return (0 ..< target).map { index in
            let low = Int(Double(index) * bucket)
            let high = min(peaks.count, max(low + 1, Int(Double(index + 1) * bucket)))
            return peaks[low ..< high].max() ?? 0
        }
    }
}

/// The lesson's recording: play/pause, skip back, the waveform, and the clock.
struct LessonPlayer: View {
    let player: LessonAudioPlayer
    let api: BackendAPI
    let lessonId: String
    let peaks: [Double]

    var body: some View {
        HStack(spacing: 14) {
            playButton
            VStack(spacing: 4) {
                scrubber
                HStack {
                    Text(timeString(player.currentTime))
                    Spacer()
                    Text(trailingLabel)
                        .foregroundStyle(player.errorMessage != nil ? .red : .secondary)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            skipBackButton
        }
    }

    private var playButton: some View {
        Button {
            Task {
                guard await player.ensureLoaded(api: api, lessonId: lessonId) else { return }
                if !player.isPlaying, player.currentTime == 0 {
                    player.playFrom(0)
                } else {
                    player.togglePlayPause()
                }
            }
        } label: {
            ZStack {
                Circle().fill(Theme.accent)
                if player.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        // play reads centred when nudged off centre
                        .offset(x: player.isPlaying ? 0 : 1.5)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
    }

    /// Only offered once there is something to go back through.
    @ViewBuilder
    private var skipBackButton: some View {
        Button {
            player.seek(to: max(0, player.currentTime - 15))
        } label: {
            Image(systemName: "gobackward.15")
                .font(.system(size: 20))
                .foregroundStyle(player.isReady ? Theme.accent : Color(.tertiaryLabel))
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady)
        .accessibilityLabel("15 Sekunden zurück")
    }

    @ViewBuilder
    private var scrubber: some View {
        if peaks.isEmpty {
            // No envelope (no audio, or a server that cannot decode it): a
            // plain track still scrubs, and says so by looking like one.
            ProgressView(value: fraction)
                .frame(height: 38)
        } else {
            WaveformScrubber(peaks: peaks, progress: fraction) { target in
                Task {
                    guard await player.ensureLoaded(api: api, lessonId: lessonId) else { return }
                    player.seek(to: target * max(player.duration, 0))
                }
            }
        }
    }

    private var fraction: Double {
        player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0
    }

    private var trailingLabel: String {
        if player.errorMessage != nil { return "Audio nicht verfügbar" }
        if player.isReady { return "−" + timeString(max(0, player.duration - player.currentTime)) }
        return "Aufnahme abspielen"
    }

    private func timeString(_ time: Double) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
