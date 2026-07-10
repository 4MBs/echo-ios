import SwiftUI

/// The big button: "answer whatever the teacher just asked".
struct AnswerButton: View {
    @Environment(AppModel.self) private var model

    private var busy: Bool { model.answers.hasInflightRequest }

    var body: some View {
        Button {
            model.pressAnswerButton()
        } label: {
            HStack {
                if busy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(busy ? "Thinking…" : "Answer Last 30 Seconds")
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(model.phase == .disconnected)
        .accessibilityHint("Sends the last 30 seconds of transcript to the AI and shows its answer")
    }
}

/// Shows the most recent answer request: loading, answer text, or error.
struct AnswerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let record = model.answers.current {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("AI Answer", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                    Spacer()
                    Text("#\(record.id) · \(record.pressedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                content(for: record)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .animation(.default, value: record)
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
        case .success(let text, let latencyMs):
            Text(text)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            Text("\(String(format: "%.1f", latencyMs / 1000)) s server-side")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failure(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}
