import SwiftUI

/// Live transcript on a notebook card. The connection status lives in the
/// card header (small dot + label) instead of a separate pill, and there is
/// no speaker column — the ASR model does not diarize.
struct TranscriptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .paperCard(cornerRadius: 18)
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot()
            Text(statusLabel)
                .font(.subheadline.weight(.semibold))
            if model.isTranscribing {
                Text("· wird transkribiert…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rtt = model.lastRoundTripMs,
               model.phase == .recording || model.phase == .connected {
                Text("\(Int(rtt)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var statusLabel: String {
        model.phase == .recording ? "Live" : model.phase.label
    }

    @ViewBuilder
    private var content: some View {
        if model.segments.isEmpty && model.partial.isEmpty {
            TranscriptEmptyState()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.segments) { segment in
                            SegmentRow(segment: segment, isPartial: false)
                        }
                        ForEach(model.partial) { segment in
                            SegmentRow(segment: segment, isPartial: true)
                        }
                        Color.clear.frame(height: 2).id("bottom")
                    }
                    .padding(.horizontal, 18)
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

/// Colored connection indicator; pulses while connecting/reconnecting.
struct StatusDot: View {
    @Environment(AppModel.self) private var model

    private var isBusy: Bool {
        model.phase == .connecting || model.phase == .reconnecting
    }

    var body: some View {
        Circle()
            .fill(model.phase.color)
            .frame(width: 9, height: 9)
            .opacity(isBusy ? 0.35 : 1)
            .animation(
                isBusy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: isBusy
            )
    }
}

struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isRecording ? "ear" : "waveform.slash")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(
                isRecording
                    ? "Ich höre zu — Gesprochenes erscheint hier."
                    : "Starte die Aufnahme, um das Live-Transkript zu sehen."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
