import SwiftUI

/// Live transcript, full-bleed like a Notes page. Status and controls live
/// in the bottom bar; there is no speaker column — the ASR model does not
/// diarize.
struct TranscriptPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.segments.isEmpty && model.partial.isEmpty {
            TranscriptEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.segments) { segment in
                            SegmentRow(segment: segment, isPartial: false)
                        }
                        ForEach(model.partial) { segment in
                            SegmentRow(segment: segment, isPartial: true)
                        }
                        Color.clear.frame(height: 2).id("bottom")
                    }
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .onChange(of: model.segments.count) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.partial) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

/// What fills the transcript area before there is a transcript: at rest, the
/// resting screen; while recording, one quiet line until the first words land.
struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.phase == .recording {
            Label("Warte auf die ersten Wörter…", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative)
                .transition(.opacity)
        } else {
            RestingScreen()
        }
    }
}

/// The screen between lessons. It used to be a title-sized announcement that
/// nothing had happened, and then nothing at all, which was honest but dead.
///
/// Now it answers the only question worth asking here — what is about to be
/// recorded — from the timetable already in memory, and keeps the clock running
/// underneath it. Both redraw themselves every minute, so the page is never
/// quite still, and neither needs a request to the server.
struct RestingScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 6) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                if let lesson = model.timetable.current ?? model.timetable.next {
                    lessonView(lesson, isNow: model.timetable.current != nil, now: context.date)
                        .padding(.top, 26)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 32)
            .multilineTextAlignment(.center)
            .animation(.snappy, value: model.timetable.current)
        }
    }

    @ViewBuilder
    private func lessonView(_ lesson: BackendAPI.Lesson, isNow: Bool, now: Date) -> some View {
        VStack(spacing: 8) {
            if let countdown = countdown(for: lesson, isNow: isNow, now: now) {
                Text(countdown)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isNow ? Color.orange : Theme.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        (isNow ? Color.orange : Theme.accent).opacity(0.14),
                        in: Capsule()
                    )
                    .contentTransition(.numericText())
            }

            Text(lesson.subjectLong ?? lesson.title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(lesson.cancelled ? .secondary : .primary)
                .strikethrough(lesson.cancelled)

            Text(details(lesson))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// "in 12 Min" before it starts, "noch 34 Min" once it is running — the one
    /// number on this screen that keeps moving on its own.
    private func countdown(for lesson: BackendAPI.Lesson, isNow: Bool, now: Date) -> String? {
        if lesson.cancelled { return "entfällt" }
        if isNow {
            guard let end = lesson.endDate, end > now else { return "Jetzt" }
            return "noch \(spell(end.timeIntervalSince(now)))"
        }
        guard let start = lesson.startDate, start > now else { return nil }
        return "in \(spell(start.timeIntervalSince(now)))"
    }

    private func spell(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) Min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) Std" : "\(hours) Std \(rest) Min"
    }

    private func details(_ lesson: BackendAPI.Lesson) -> String {
        var parts = ["\(lesson.start)–\(lesson.end)"]
        if !lesson.room.isEmpty { parts.append("Raum \(lesson.room)") }
        if !lesson.teacher.isEmpty { parts.append(lesson.teacher) }
        return parts.joined(separator: " · ")
    }
}

/// One transcript line: faint timestamp, then the text. Partial (still
/// changing) lines are italic and dimmed.
struct SegmentRow: View {
    let segment: TranscriptSegment
    let isPartial: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
            Text(segment.text)
                .font(.body)
                .lineSpacing(3)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timestamp: String {
        let total = Int(segment.t0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
