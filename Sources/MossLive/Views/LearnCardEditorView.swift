import SwiftUI

struct LearnCardEditorView: View {
    let api: BackendAPI
    let card: BackendAPI.LearnCard
    let onSaved: (BackendAPI.LearnCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var concept: String
    @State private var question: String
    @State private var expected: String
    @State private var explanation: String
    @State private var difficulty: Int
    @State private var saving = false
    @State private var errorMessage: String?

    init(api: BackendAPI, card: BackendAPI.LearnCard, onSaved: @escaping (BackendAPI.LearnCard) -> Void) {
        self.api = api; self.card = card; self.onSaved = onSaved
        _concept = State(initialValue: card.concept ?? "")
        _question = State(initialValue: card.question)
        _expected = State(initialValue: card.expectedAnswer ?? "")
        _explanation = State(initialValue: card.explanation)
        _difficulty = State(initialValue: card.difficulty)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Konzept", text: $concept)
                TextField("Frage", text: $question, axis: .vertical)
                TextField("Erwartete Antwort", text: $expected, axis: .vertical)
                TextField("Erklärung", text: $explanation, axis: .vertical)
                Stepper("Schwierigkeit \(difficulty) von 5", value: $difficulty, in: 1 ... 5)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Lernkarte bearbeiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }.disabled(saving || question.isEmpty)
                }
            }
        }
    }

    private func save() async {
        saving = true
        do {
            let updated = try await api.updateLearnCard(id: card.id, changes: [
                "concept": concept, "question": question, "expected_answer": expected,
                "explanation": explanation, "difficulty": difficulty
            ])
            onSaved(updated); dismiss()
        } catch { errorMessage = error.localizedDescription }
        saving = false
    }
}
