import SwiftUI
import UIKit

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
                .font(.caption)
                .foregroundStyle(copied ? Theme.accent : Color(.tertiaryLabel))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Kopiert" : accessibilityLabel)
        .sensoryFeedback(.success, trigger: copied)
        .onDisappear { resetTask?.cancel() }
    }
}
