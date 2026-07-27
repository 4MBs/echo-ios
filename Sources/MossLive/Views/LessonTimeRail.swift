import SwiftUI

/// What this lesson is: which subject, which day, which slot, who taught it.
struct LessonHeadline: View {
    let info: BackendAPI.LessonInfo
    let style: SubjectStyle
    var compact = false

    var body: some View {
        if compact {
            HStack(alignment: .top, spacing: 14) {
                glyph
                VStack(alignment: .leading, spacing: 3) { stack }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                glyph.padding(.bottom, 12)
                stack
            }
        }
    }

    /// The subject's own mark, bare rather than in the archive's coloured tile:
    /// the tile means "a folder full of these", and this is one of them.
    private var glyph: some View {
        Image(systemName: style.symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(style.color)
    }

    @ViewBuilder
    private var stack: some View {
        Text(day)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        Text(slot)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        if let people {
            Text(people)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private var day: String {
        info.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The slot it filled, not just when it began — a lesson is a span, and the
    /// span is what the timeline below is a picture of.
    private var slot: String {
        let end = info.startedAt.addingTimeInterval(info.durationSeconds)
        let from = info.startedAt.formatted(date: .omitted, time: .shortened)
        let till = end.formatted(date: .omitted, time: .shortened)
        let minutes = max(1, Int((info.durationSeconds / 60).rounded()))
        return "\(from) – \(till) · \(minutes) Min"
    }

    private var people: String? {
        var parts: [String] = []
        if let teacher = info.teacher, !teacher.isEmpty { parts.append(teacher) }
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The left rail: the lesson's identity, and the recording as a column of time.
struct LessonTimeRail: View {
    let info: BackendAPI.LessonInfo
    let style: SubjectStyle
    let peaks: [Double]
    let duration: Double
    let hasAudio: Bool
    let cachedAt: Date?
    let player: LessonAudioPlayer
    let playhead: LessonPlayhead
    let toggle: () -> Void
    let skip: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LessonHeadline(info: info, style: style)
            if let cachedAt {
                // Said here, quietly, rather than as a banner over the content:
                // everything on the page still works, it is just not fresh.
                Text("Gespeichert \(CacheAge.phrase(cachedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
            if hasAudio {
                LessonWave(
                    peaks: peaks, duration: duration, tint: style.color,
                    axis: .vertical, player: player, playhead: playhead
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 26)
                LessonTransport(
                    player: player, tint: style.color, duration: duration,
                    playhead: playhead, toggle: toggle, skip: skip
                )
            } else {
                Spacer(minLength: 0)
                Label("Keine Aufnahme", systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 26)
    }
}

/// The recording where a narrow window has to put it.
///
/// Time runs across here instead of down. In a slide-over there is no column to
/// run it in, and the wrong axis is better than a waveform four points wide.
struct LessonTransportBar: View {
    let peaks: [Double]
    let duration: Double
    let tint: Color
    let player: LessonAudioPlayer
    let playhead: LessonPlayhead
    let toggle: () -> Void
    let skip: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 12) {
                LessonWave(
                    peaks: peaks, duration: duration, tint: tint,
                    axis: .horizontal, player: player, playhead: playhead
                )
                .frame(height: 44)
                LessonTransport(
                    player: player, tint: tint, duration: duration,
                    playhead: playhead, toggle: toggle, skip: skip, stacked: false
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }
}

/// Play, and the two jumps that actually get used when a sentence went past.
///
/// Reads `isPlaying` and `isLoading`, which change when something happens, and
/// pointedly not `currentTime`, which changes seven times a second. The clock
/// is a view of its own for exactly that reason.
struct LessonTransport: View {
    let player: LessonAudioPlayer
    let tint: Color
    let duration: Double
    let playhead: LessonPlayhead
    let toggle: () -> Void
    let skip: (Double) -> Void
    var stacked = true

    var body: some View {
        VStack(spacing: 10) {
            if stacked {
                LessonClock(player: player, playhead: playhead, duration: duration)
                controls
            } else {
                HStack(spacing: 18) {
                    LessonClock(player: player, playhead: playhead, duration: duration)
                    Spacer(minLength: 0)
                    controls
                }
            }
            if let message = player.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: stacked ? 26 : 20) {
            jump(-15, "gobackward.15")
            playButton
            jump(15, "goforward.15")
        }
    }

    private var playButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle().fill(tint)
                if player.isLoading {
                    ProgressView().tint(Color.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: stacked ? 21 : 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: stacked ? 56 : 44, height: stacked ? 56 : 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
    }

    private func jump(_ delta: Double, _ symbol: String) -> some View {
        Button {
            skip(delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: stacked ? 21 : 18))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "15 Sekunden zurück" : "15 Sekunden vor")
    }
}

/// The one piece of text on the screen that changes seven times a second, kept
/// in a view of its own so that it is the only thing that redraws.
struct LessonClock: View {
    let player: LessonAudioPlayer
    let playhead: LessonPlayhead
    let duration: Double

    var body: some View {
        let head = max(player.currentTime, playhead.time)
        return Text("\(lessonOffsetLabel(head)) / \(lessonOffsetLabel(duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// The recording drawn as its own peaks, along whichever axis time runs in.
///
/// This reads `currentTime`, which is why it is a view of its own: it redraws
/// with the playhead and nothing around it does. What it redraws is one canvas
/// of a couple of hundred bars, which is the cheap half of the screen — the
/// expensive half is the transcript, and the transcript never asks the clock.
struct LessonWave: View {
    let peaks: [Double]
    let duration: Double
    let tint: Color
    let axis: Axis
    let player: LessonAudioPlayer
    let playhead: LessonPlayhead

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, max(player.currentTime, playhead.time) / duration))
    }

    var body: some View {
        let progress = fraction
        return GeometryReader { geo in
            let span = axis == .vertical ? geo.size.height : geo.size.width
            ZStack(alignment: axis == .vertical ? .topLeading : .leading) {
                Canvas { context, size in
                    draw(&context, size, progress)
                }
                head(at: span * CGFloat(progress))
            }
            .contentShape(Rectangle())
            .gesture(scrub(span: span))
        }
        .accessibilityElement()
        .accessibilityLabel("Aufnahme")
        .accessibilityValue(lessonOffsetLabel(progress * duration))
    }

    @ViewBuilder
    private func head(at offset: CGFloat) -> some View {
        if axis == .vertical {
            Capsule().fill(tint).frame(height: 3).offset(y: offset - 1.5)
        } else {
            Capsule().fill(tint).frame(width: 3).offset(x: offset - 1.5)
        }
    }

    private func scrub(span: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = axis == .vertical ? value.location.y : value.location.x
                let ratio = Double(min(max(0, point / max(span, 1)), 1))
                playhead.time = ratio * duration
                // A no-op until the recording has been downloaded, which is the
                // point of keeping the mark separately: the timeline can be
                // aimed before there is anything to play.
                player.seek(to: ratio * duration)
            }
    }

    /// Downsampled to the room there actually is. Four hundred peaks in a
    /// column three hundred points tall is a solid block, not a waveform.
    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ progress: Double) {
        let along = axis == .vertical ? size.height : size.width
        let across = axis == .vertical ? size.width : size.height
        guard along > 4, across > 2 else { return }
        let idle = Color.primary.opacity(0.16)
        let played = along * CGFloat(progress)
        guard !peaks.isEmpty else {
            // No peaks yet — a bare track, so the scrubber is still aimable.
            fillTrack(&context, along: along, across: across, from: 0, to: played, color: tint)
            fillTrack(&context, along: along, across: across, from: played, to: along, color: idle)
            return
        }
        let bars = max(1, Int(along / 3.5))
        let step = along / CGFloat(bars)
        for bar in 0 ..< bars {
            let lower = peaks.count * bar / bars
            let upper = min(max(lower + 1, peaks.count * (bar + 1) / bars), peaks.count)
            let peak = peaks[lower ..< upper].max() ?? 0
            let thick = max(2, CGFloat(peak) * across)
            let offset = CGFloat(bar) * step
            let length = max(1.5, step - 1.6)
            let rect = axis == .vertical
                ? CGRect(x: (across - thick) / 2, y: offset, width: thick, height: length)
                : CGRect(x: offset, y: (across - thick) / 2, width: length, height: thick)
            let radius = min(rect.width, rect.height) / 2
            context.fill(
                Path(roundedRect: rect, cornerRadius: radius),
                with: .color(offset + step <= played ? tint : idle)
            )
        }
    }

    private func fillTrack(
        _ context: inout GraphicsContext,
        along: CGFloat,
        across: CGFloat,
        from: CGFloat,
        to: CGFloat,
        color: Color
    ) {
        guard to > from else { return }
        let rect = axis == .vertical
            ? CGRect(x: (across - 3) / 2, y: from, width: 3, height: to - from)
            : CGRect(x: from, y: (across - 3) / 2, width: to - from, height: 3)
        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
    }
}
