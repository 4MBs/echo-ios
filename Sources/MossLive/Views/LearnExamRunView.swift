import SwiftUI

struct LearnExamRunView: View {
    let api: BackendAPI
    @State private var run: BackendAPI.LearnExamRun
    @State private var index = 0
    @State private var answer = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(api: BackendAPI, initialRun: BackendAPI.LearnExamRun) { self.api = api; _run = State(initialValue: initialRun) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if run.status == "submitted" {
                        ContentUnavailableView("Probeprüfung abgegeben", systemImage: "checkmark.seal.fill", description: Text("\(run.score ?? 0, specifier: "%.0f") von \(run.maxPoints, specifier: "%.0f") Punkten"))
                    } else if run.questions.indices.contains(index) {
                        let question = run.questions[index]
                        Text("Aufgabe \(index + 1) von \(run.questions.count) · \(question.points) Punkte").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(index), total: Double(max(1, run.questions.count)))
                        Text(question.question).font(.title2.bold())
                        LearnAnswerSpecView(spec: question.answerSpec, answer: $answer)
                        Button(index + 1 == run.questions.count ? "Prüfung abgeben" : "Antwort speichern und weiter") { Task { await next(question) } }
                            .buttonStyle(.borderedProminent).disabled(submitting)
                    } else {
                        ContentUnavailableView("Keine Aufgaben", systemImage: "doc.text")
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }.padding(24)
            }
            .navigationTitle("Probeprüfung")
            .toolbar { Button("Schließen") { dismiss() } }
        }
        .interactiveDismissDisabled(run.status != "submitted")
    }

    private func next(_ question: BackendAPI.LearnExamRun.Question) async {
        submitting = true
        do {
            try await api.saveLearnExamAnswer(runId: run.id, cardId: question.id, answer: answer)
            if index + 1 == run.questions.count { run = try await api.submitLearnExam(runId: run.id) }
            else { index += 1; answer = "" }
        } catch { errorMessage = error.localizedDescription }
        submitting = false
    }
}
