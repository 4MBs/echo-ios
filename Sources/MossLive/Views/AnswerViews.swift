import SwiftUI
import UIKit

/// The big button: "answer whatever the teacher just asked".
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
                }
                Text(busy ? "Thinking…" : "Answer Last 30 Seconds")
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.glassProminent)
        .tint(.purple)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .animation(.default, value: busy)
        .accessibilityHint("Sends the last 30 seconds of transcript to the AI and shows its answer")
    }
}

/// Shows the most recent answer request: loading, streaming, answer, or error.
struct AnswerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let record = model.answers.current {
            VStack(alignment: .leading, spacing: 10) {
                header(for: record)
                content(for: record)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.purple.opacity(0.14)), in: .rect(cornerRadius: 20))
            .animation(.default, value: record)
        }
    }

    private func header(for record: AnswerTracker.Record) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("AI Answer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
            Spacer()
            if case .success(let text, _) = record.state {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Copy answer")
            }
            Text("#\(record.id) · \(record.pressedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func content(for record: AnswerTracker.Record) -> some View {
        switch record.state {
        case .pending:
            Label("Sending request…", systemImage: "paperplane")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .waitingForAnswer:
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for the AI answer…")
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
            Text("answered in \(String(format: "%.1f", latencyMs / 1000)) s")
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
