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
/// one quiet line until the first words land. At rest, deliberately nothing —
/// the page is left blank.
struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.phase == .recording {
            Label("Warte auf die ersten Wörter…", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative)
                .transition(.opacity)
        }
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
