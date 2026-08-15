import SwiftUI

struct LearnRemediationView: View {
    let api: BackendAPI
    let card: BackendAPI.LearnCard
    let remediation: BackendAPI.LearnRemediation
    let onPassed: () -> Void

    @State private var answer = ""
    @State private var feedback: BackendAPI.LearnEvaluation?
    @State private var isChecking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Konzept noch einmal festigen", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(remediation.diagnosis).font(.title3.bold())
            Text(remediation.explanation)
            if let source = remediation.source {
                NavigationLink {
                    LearnSourceView(source: source)
                } label: {
                    Label("Erklärung in der Stunde öffnen", systemImage: "text.quote")
                }
            }
            DisclosureGroup("Hinweis") { Text(remediation.hint).padding(.top, 6) }
            Divider()
            Text("Kontrollfrage").font(.caption).foregroundStyle(.secondary)
            Text(remediation.controlQuestion).font(.title3.bold())
            TextEditor(text: $answer)
                .frame(minHeight: 110)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            if let feedback {
                Label(feedback.feedback, systemImage: feedback.category == .correct ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                    .foregroundStyle(feedback.category == .correct ? .green : .orange)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Button(feedback?.category == .correct ? "Weiter" : "Kontrollantwort prüfen") {
                if feedback?.category == .correct { onPassed() } else { Task { await check() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
        }
    }

    private func check() async {
        isChecking = true
        errorMessage = nil
        do {
            feedback = try await api.evaluateRemediation(
                cardId: card.id, remediation: remediation, answer: answer
            ).evaluation
        } catch {
            errorMessage = error.localizedDescription
        }
        isChecking = false
    }
}
