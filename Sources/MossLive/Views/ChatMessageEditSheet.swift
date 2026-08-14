import SwiftUI

/// Editing a sent question replaces it and re-runs the conversation from
/// that point, so the sheet says so before the student commits to it.
struct ChatMessageEditSheet: View {
    let message: ChatStore.Message
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(message: ChatStore.Message, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nachfolgende Antworten werden entfernt und neu erstellt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Nachricht bearbeiten", text: $text, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .accessibilityIdentifier("chat.edit.input")
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Nachricht bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
