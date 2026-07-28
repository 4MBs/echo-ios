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
    /// How tall the bars are drawn. The lesson page gives it more room than a
    /// row-sized control would.
    var height: CGFloat = 38

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
        .frame(height: height)
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

/// The lesson's recording as a panel: the waveform across the full width, the
/// clock under its two ends, and the transport centred below.
///
/// The waveform is the widest thing here because it is the only part that has
/// something to say before you press anything — where the talking is, and where
/// the twenty minutes of group work are. The transport is centred under it
/// rather than beside it, so the eye lands on the waveform first and the buttons
/// sit where a thumb already expects them.
struct LessonPlayer: View {
    let player: LessonAudioPlayer
    let api: BackendAPI
    let lessonId: String
    let peaks: [Double]
    /// The length the archive knows, shown until the file itself is loaded —
    /// otherwise the header reads 0:00 until the first press.
    let knownDuration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 6) {
                scrubber
                clock
            }
            transport
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Audio")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("·")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Text(timeString(totalDuration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Waveform and clock

    @ViewBuilder
    private var scrubber: some View {
        if peaks.isEmpty {
            // No envelope (no audio, or a server that cannot decode it): a
            // plain track still scrubs, and says so by looking like one.
            ProgressView(value: fraction)
                .frame(height: 52)
        } else {
            WaveformScrubber(
                peaks: peaks,
                progress: fraction,
                onScrub: { target in
                    Task {
                        guard await player.ensureLoaded(api: api, lessonId: lessonId) else { return }
                        player.seek(to: target * max(player.duration, 0))
                    }
                },
                height: 52
            )
        }
    }

    private var clock: some View {
        HStack {
            Text(timeString(player.currentTime))
            Spacer(minLength: 0)
            Text(timeString(totalDuration))
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 26) {
            skipButton(seconds: -15, symbol: "gobackward.15", label: "15 Sekunden zurück")
            playButton
            skipButton(seconds: 15, symbol: "goforward.15", label: "15 Sekunden vor")
        }
        .frame(maxWidth: .infinity)
    }

    /// A stock `borderedProminent` circle rather than a filled `Circle` with a
    /// glyph on top. The system styles carry the current design — the tint, the
    /// pressed state, the shadow, the way all of it shifts under Liquid Glass —
    /// and a hand-drawn shape carries whatever it was drawn to look like on the
    /// day it was written.
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
            if player.isLoading {
                ProgressView()
            } else {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
    }

    private func skipButton(seconds: Double, symbol: String, label: String) -> some View {
        Button {
            let target = player.currentTime + seconds
            player.seek(to: min(max(0, target), max(0, player.duration)))
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!player.isReady)
        .accessibilityLabel(label)
    }

    // MARK: - Footer

    /// The speed sits out at the edge and the status in the middle, so the
    /// status can be centred under the transport without the speed pushing it
    /// off-centre when its label grows from "1 ×" to "1,25 ×".
    private var footer: some View {
        ZStack {
            Text(statusLabel)
                .font(.footnote)
                .foregroundStyle(player.errorMessage != nil ? .red : .secondary)
                .frame(maxWidth: .infinity)
            HStack {
                rateMenu
                Spacer(minLength: 0)
            }
        }
    }

    /// A stock bordered capsule menu. The pill it replaces was the same shape
    /// drawn by hand, which is one more thing that has to be re-drawn every
    /// time the system's own capsules change.
    private var rateMenu: some View {
        Menu {
            Picker("Geschwindigkeit", selection: rateBinding) {
                ForEach(LessonAudioPlayer.rates, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(rateLabel(player.rate))
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityLabel("Wiedergabegeschwindigkeit")
    }

    private var rateBinding: Binding<Double> {
        Binding(get: { player.rate }, set: { player.setRate($0) })
    }

    private func rateLabel(_ rate: Double) -> String {
        let number = rate.formatted(.number.precision(.fractionLength(0 ... 2)))
        return "\(number) ×"
    }

    // MARK: - Values

    /// The archive's length until the file is loaded, then the file's own —
    /// they agree, but only one of them exists before the first press.
    private var totalDuration: Double {
        player.isReady ? player.duration : knownDuration
    }

    private var fraction: Double {
        let total = totalDuration
        return total > 0 ? min(player.currentTime / total, 1) : 0
    }

    private var statusLabel: String {
        if let errorMessage = player.errorMessage { return errorMessage }
        if player.isPlaying { return "Wird abgespielt" }
        return "Aufnahme abspielen"
    }

    private func timeString(_ time: Double) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
