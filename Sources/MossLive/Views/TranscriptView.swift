import SwiftUI

/// Live transcript, notebook-style: a timestamp column on the left, the
/// speaker named once per turn, and the still-changing tail in italics.
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
            Circle()
                .fill(model.phase == .recording ? .red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            Text(model.phase == .recording ? "Live" : "Transkript")
                .font(.subheadline.weight(.semibold))
            if model.isTranscribing {
                Text("– wird transkribiert…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.segments.isEmpty {
                Text("\(model.segments.count) Abschnitte")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// With a single speaker (the current model does not diarize) the speaker
    /// column is pure noise, so it only appears when speakers actually differ.
    private var isMultiSpeaker: Bool {
        let speakers = Set(model.segments.map(\.speaker)).union(model.partial.map(\.speaker))
        return speakers.count > 1
    }

    @ViewBuilder
    private var content: some View {
        if model.segments.isEmpty && model.partial.isEmpty {
            TranscriptEmptyState()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                            SegmentRow(
                                segment: segment,
                                isPartial: false,
                                speakerStyle: rowStyle(
                                    changed: index == 0 || model.segments[index - 1].speaker != segment.speaker
                                )
                            )
                        }
                        ForEach(Array(model.partial.enumerated()), id: \.element.id) { index, segment in
                            SegmentRow(
                                segment: segment,
                                isPartial: true,
                                speakerStyle: rowStyle(
                                    changed: index == 0
                                        ? model.segments.last?.speaker != segment.speaker
                                        : model.partial[index - 1].speaker != segment.speaker
                                )
                            )
                        }
                        Color.clear.frame(height: 2).id("bottom")
                    }
                    .padding(14)
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

    private func rowStyle(changed: Bool) -> SegmentRow.SpeakerStyle {
        guard isMultiSpeaker else { return .hidden }
        return changed ? .shown : .placeholder
    }
}

struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isRecording ? "ear" : "mic.slash")
                .font(.system(size: 34))
                .foregroundStyle(.quaternary)
            Text(
                isRecording
                    ? "Ich höre zu — Gesprochenes erscheint hier."
                    : "Starte die Aufnahme, um das Live-Transkript zu sehen."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct SegmentRow: View {
    /// hidden = no speaker column at all (single-speaker transcript);
    /// placeholder = keep the column aligned but show nothing (same speaker
    /// as the previous row); shown = speaker name visible.
    enum SpeakerStyle {
        case hidden, placeholder, shown
    }

    let segment: TranscriptSegment
    let isPartial: Bool
    var speakerStyle: SpeakerStyle = .shown

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            if speakerStyle != .hidden {
                Text(speakerName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SpeakerBadge.color(for: segment.speaker))
                    .opacity(speakerStyle == .shown ? 1 : 0)
                    .frame(width: 86, alignment: .leading)
            }
            Text(segment.text)
                .font(.callout)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speakerName: String {
        "Sprecher \(Int(segment.speaker.dropFirst()) ?? 0)"
    }

    private var timestamp: String {
        let total = Int(segment.t0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum SpeakerBadge {
    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]

    static func color(for speaker: String) -> Color {
        let index = (Int(speaker.dropFirst()) ?? 0) - 1
        return palette[abs(index) % palette.count]
    }
}
