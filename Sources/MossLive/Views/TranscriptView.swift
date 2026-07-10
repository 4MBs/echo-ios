import SwiftUI

/// Live transcript: committed segments plus the italic, still-changing tail.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.segments.isEmpty && model.partial.isEmpty {
                        Text("The live transcript appears here.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.segments) { segment in
                        SegmentRow(segment: segment, isPartial: false)
                    }
                    ForEach(model.partial) { segment in
                        SegmentRow(segment: segment, isPartial: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxHeight: .infinity)
            .onChange(of: model.segments.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.partial) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let isPartial: Bool

    private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]

    private var speakerColor: Color {
        let index = (Int(segment.speaker.dropFirst()) ?? 0) - 1
        return Self.palette[abs(index) % Self.palette.count]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.speaker)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(speakerColor)
                .frame(width: 34, alignment: .leading)
            Text(segment.text)
                .font(.callout)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
            Spacer(minLength: 0)
            Text(timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var timestamp: String {
        let total = Int(segment.t0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
