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

/// What fills the transcript area before there is a transcript: while recording,
/// one quiet line until the first words land. At rest, one quiet paragraph
/// that says what this page is for.
///
/// It used to be nothing at all at rest. That kept the screen calm, but a
/// blank page above a single button gave no hint that the button fills the
/// page — the first recording of every install began by guessing. The text is
/// set in the faintest colours the system has, so it is calm all the same.
struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 40

    var body: some View {
        Group {
            if model.phase == .recording {
                Label("Warte auf die ersten Wörter…", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .symbolEffect(.variableColor.iterative)
            } else if !model.isRecording {
                idle
            }
        }
        .transition(.opacity)
        .animation(.smooth(duration: 0.3), value: model.phase == .recording)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: glyphSize, weight: .ultraLight))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("Bereit für die Stunde")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Starte unten die Aufnahme. Was gesagt wird, erscheint hier.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// One transcript line: faint timestamp, then the text. Partial (still
/// changing) lines are italic and dimmed.
struct SegmentRow: View {
    let segment: TranscriptSegment
    let isPartial: Bool
    /// The line currently being spoken, while the recording plays.
    var isActive = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            stamp
                .frame(width: 42, alignment: .trailing)
            Text(segment.text)
                .font(.body)
                .lineSpacing(3)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Written as two branches rather than one conditional style: `.tertiary`
    /// and a `Color` are different types, and the ternary would need erasing
    /// through `AnyShapeStyle` to sit in one expression.
    @ViewBuilder
    private var stamp: some View {
        let text = Text(timestamp).font(.caption.monospacedDigit())
        if isActive {
            text.foregroundStyle(Theme.accent)
        } else {
            text.foregroundStyle(.tertiary)
        }
    }

    private var timestamp: String {
        let total = Int(segment.t0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
