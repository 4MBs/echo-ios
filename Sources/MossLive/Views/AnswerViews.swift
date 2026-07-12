import SwiftUI
import UIKit

/// Compact secondary action; recording remains the only visually dominant control.
struct AnswerButton: View {
    @Environment(AppModel.self) private var model

    private var busy: Bool { model.answers.hasInflightRequest }
    private var disabled: Bool { model.phase == .disconnected || model.phase == .connecting }

    var body: some View {
        Button {
            model.pressAnswerButton()
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.purple)
                }
                Text(busy ? "Denkt nach…" : "Ask about the last 30 seconds")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.purple.opacity(0.18)) }
        .buttonBorderShape(.roundedRectangle(radius: 22))
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .animation(.default, value: busy)
        .accessibilityHint("Sends the last 30 seconds of transcript to the AI and shows its answer")
    }
}

/// Right column: the AI assistant panel — always present, showing the latest
/// answer (or an empty prompt). Mirrors the transcript card's glass styling.
struct AIAssistantCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.purple.opacity(0.15)) }
        .frame(maxHeight: .infinity)
        .animation(.default, value: model.answers.current)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("AI Assistant")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
            Spacer()
            if let record = model.answers.current, case .success(let text, _) = record.state {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Copy answer")
            }
            if let record = model.answers.current {
                Text("#\(record.id) · \(record.pressedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let record = model.answers.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    answerBody(for: record)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else {
            AIEmptyState()
        }
    }

    @ViewBuilder
    private func answerBody(for record: AnswerTracker.Record) -> some View {
        switch record.state {
        case .pending:
            Label("Anfrage wird gesendet…", systemImage: "paperplane")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .waitingForAnswer:
            HStack(spacing: 8) {
                ProgressView()
                Text("Warte auf die Antwort…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .streaming(let partial):
            Text(rendered(partial + " …"))
                .font(.body)
                .textSelection(.enabled)
        case .success(let text, let latencyMs):
            Text(rendered(text))
                .font(.body)
                .textSelection(.enabled)
            Text("Antwort in \(String(format: "%.1f", latencyMs / 1000)) s generiert")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failure(let error):
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    /// The backend asks Gemini for plain text, but render any inline Markdown
    /// that slips through instead of showing raw asterisks.
    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct AIEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.purple.opacity(0.5))
            Text("Tippe auf „Letzte 30 Sekunden beantworten“, um die Antwort der KI hier zu sehen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
