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

/// Red "LIVE" capsule shown while recording.
struct LivePill: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 6, height: 6)
            Text("LIVE")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red, in: Capsule())
    }
}

/// Connection status: small colored dot + label, like a system status row.
struct StatusLabel: View {
    let phase: AppModel.Phase

    private var color: Color {
        switch phase {
        case .disconnected: .gray
        case .connecting, .reconnecting: .orange
        case .connected: .green
        case .recording: .red
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Empty transcript area. Built by hand rather than with ContentUnavailableView
/// so the symbol can animate: while recording it travels, which is the only
/// thing on the page saying "still listening" before the first words land.
struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isRecording ? "waveform" : "mic")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, isActive: isRecording)
                .padding(.bottom, 2)

            Text(isRecording ? "Ich höre zu" : "Bereit für die nächste Stunde")
                .font(.title3.weight(.semibold))

            Text(
                isRecording
                    ? "Gesprochenes erscheint hier."
                    : "Die Aufnahme wird live transkribiert und automatisch der richtigen Stunde zugeordnet."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 430)
        }
        .padding(.horizontal, 32)
        .animation(.snappy, value: isRecording)
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
