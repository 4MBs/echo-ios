import SwiftUI

/// Full-screen lesson summary, shown after a recording session ends.
/// The server generates it from the complete transcript while this sheet
/// shows its progress state.
struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("Lesson Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if case .ready(let text, _, _) = model.summaryState {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: text) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.summaryState {
        case .generating:
            GeneratingSummaryView()
        case .ready(let text, let duration, let date):
            ReadySummaryView(text: text, duration: duration, date: date)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        case nil:
            EmptyView()
        }
    }
}

struct GeneratingSummaryView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.badge.star")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom)
                )
                .symbolEffect(.pulse, isActive: true)
            Text("Creating your summary…")
                .font(.headline)
            Text("The whole lesson is being condensed into key points. This takes a few seconds.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .padding(.top, 4)
        }
        .padding(36)
    }
}

struct ReadySummaryView: View {
    let text: String
    let duration: TimeInterval
    let date: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    chip(icon: "calendar", label: date.formatted(date: .abbreviated, time: .shortened))
                    chip(icon: "clock", label: durationLabel)
                    Spacer()
                }
                Text(rendered)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .padding(16)
        }
    }

    private var durationLabel: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
    }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func chip(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
        .foregroundStyle(.secondary)
    }
}
