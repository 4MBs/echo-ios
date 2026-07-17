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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinedPage())
        }
        .paperCard(cornerRadius: 18)
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.phase == .recording {
                LivePill()
                Text(model.isTranscribing ? "wird transkribiert…" : "Aufnahme läuft")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                StatusStamp(text: model.phase.label)
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

/// Lined page with the classic red margin, always visible inside the
/// transcript card (also before the first word): timestamps live left of the
/// line, the spoken text right of it.
struct LinedPage: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RuledLines()
            Rectangle()
                .fill(Theme.marginLine)
                .frame(width: 1.5)
                .padding(.leading, 66)
        }
        .allowsHitTesting(false)
    }
}

/// Red "LIVE" capsule shown in the transcript header while recording.
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

/// Connection status as a faded rubber stamp pressed onto the page, instead
/// of a colored dot that has no meaning on paper.
struct StatusStamp: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(Theme.ink.opacity(0.42))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.ink.opacity(0.30), lineWidth: 1.2)
            )
            .rotationEffect(.degrees(-2))
    }
}

/// Empty page: handwritten hint instead of a gray system icon, with a doodle
/// arrow pointing down toward the record control.
struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        VStack(spacing: 8) {
            Text(isRecording ? "Ich höre zu …" : "Noch ist die Seite leer.")
                .font(Theme.handwriting(22))
                .foregroundStyle(Theme.ink.opacity(0.6))
            Text(
                isRecording
                    ? "Gesprochenes erscheint hier."
                    : "Tippe unten auf „Aufnahme starten“."
            )
            .font(Theme.handwriting(15))
            .foregroundStyle(Theme.ink.opacity(0.42))
            if !isRecording {
                Doodle(name: "doodle-arrow-se", size: 40, rotation: 40)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
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
