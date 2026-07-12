import SwiftUI

/// Live transcript card: committed segments plus the still-changing tail.
/// Consecutive rows by the same speaker share one avatar column so the
/// transcript reads like a conversation, not a log file.
struct TranscriptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(.secondarySystemGroupedBackground).opacity(0.78), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.06)) }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.teal)
                .symbolEffect(.variableColor.iterative, isActive: model.isTranscribing)
            Text("Live Transcript")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if model.phase == .recording {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.green.opacity(0.15), in: Capsule())
            }
            if !model.segments.isEmpty {
                Text("\(model.segments.count) Segmente")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// With a single speaker (the current model does not diarize) the badge
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
            Text(isRecording ? "Listening — speech appears here." : "Start recording to see the live transcript.")
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
    /// as the previous row); shown = badge visible.
    enum SpeakerStyle {
        case hidden, placeholder, shown
    }

    let segment: TranscriptSegment
    let isPartial: Bool
    var speakerStyle: SpeakerStyle = .shown

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if speakerStyle != .hidden {
                SpeakerBadge(speaker: segment.speaker)
                    .opacity(speakerStyle == .shown ? 1 : 0)
            }
            Text(segment.text)
                .font(.callout)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.quaternary)
        }
    }

    private var timestamp: String {
        let total = Int(segment.t0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SpeakerBadge: View {
    let speaker: String

    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]

    static func color(for speaker: String) -> Color {
        let index = (Int(speaker.dropFirst()) ?? 0) - 1
        return palette[abs(index) % palette.count]
    }

    var body: some View {
        Text(String(Int(speaker.dropFirst()) ?? 0))
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(Self.color(for: speaker))
            .frame(width: 24, height: 24)
            .background(Self.color(for: speaker).opacity(0.16), in: Circle())
            .accessibilityLabel("Speaker \(speaker)")
    }
}
