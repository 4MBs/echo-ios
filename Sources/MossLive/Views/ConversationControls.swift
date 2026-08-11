import SwiftUI
import UIKit

/// T3 Code's quiet in-flight assistant state: three tiny dots on the same
/// baseline as the answer that will replace them.
struct ConversationThinkingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().frame(width: 4, height: 4).opacity(1)
            Circle().frame(width: 4, height: 4).opacity(0.8)
            Circle().frame(width: 4, height: 4).opacity(0.6)
        }
        .foregroundStyle(Color(.tertiaryLabel))
        .frame(width: 20, height: 12)
        .accessibilityElement()
        .accessibilityLabel("Denkt nach")
    }
}

/// A quiet copy action with the same immediate confirmation everywhere a
/// generated answer appears. The state belongs to the button, so copying one
/// message never changes another message's controls.
struct CopyFeedbackButton: View {
    let text: String
    let accessibilityLabel: String

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            resetTask?.cancel()
            copied = true
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13))
                .foregroundStyle(copied ? Theme.accent : Color(.tertiaryLabel))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Kopiert" : accessibilityLabel)
        .sensoryFeedback(.success, trigger: copied)
        .onDisappear { resetTask?.cancel() }
    }
}
