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
                        ForEach(run.results ?? []) { result in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(result.concept, systemImage: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.headline).foregroundStyle(result.correct ? .green : .red)
                                Text("\(result.points, specifier: "%.0f") / \(result.maxPoints, specifier: "%.0f") Punkte")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(result.feedback)
                            }
                            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        }
                    } else if run.questions.indices.contains(index) {
                        let question = run.questions[index]
                        HStack {
                            Text("Aufgabe \(index + 1) von \(run.questions.count) · \(question.points) Punkte")
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in Text(remaining(at: context.date)).monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(index), total: Double(max(1, run.questions.count)))
                        Text(question.question).font(.title2.bold())
                        LearnAnswerSpecView(spec: question.answerSpec, answer: $answer)
                            .disabled(run.status == "paused")
                        Button(index + 1 == run.questions.count ? "Prüfung abgeben" : "Antwort speichern und weiter") { Task { await next(question) } }
                            .buttonStyle(.borderedProminent).disabled(submitting || run.status == "paused")
                    } else {
                        ContentUnavailableView("Keine Aufgaben", systemImage: "doc.text")
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }.padding(24)
            }
            .navigationTitle("Probeprüfung")
            .toolbar {
                if run.status != "submitted" {
                    Button(run.status == "paused" ? "Fortsetzen" : "Pausieren") { Task { await togglePause() } }
                }
                Button("Schließen") { dismiss() }
            }
        }
        .interactiveDismissDisabled(run.status == "active")
        .task(id: run.status) {
            while !Task.isCancelled, run.status == "active" {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if remainingSeconds(at: Date()) == 0 {
                    do { run = try await api.submitLearnExam(runId: run.id) }
                    catch { errorMessage = error.localizedDescription }
                    break
                }
            }
        }
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

    private func togglePause() async {
        do { run = try await api.setLearnExamRunStatus(runId: run.id, status: run.status == "paused" ? "active" : "paused") }
        catch { errorMessage = error.localizedDescription }
    }

    private func remaining(at date: Date) -> String {
        guard run.status != "paused", let start = ISO8601DateFormatter().date(from: run.startedAt) else { return "Pausiert" }
        let seconds = remainingSeconds(at: date, start: start)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func remainingSeconds(at date: Date, start: Date? = nil) -> Int {
        guard let start = start ?? ISO8601DateFormatter().date(from: run.startedAt) else { return 0 }
        return max(0, run.timeLimitMinutes * 60 - Int(date.timeIntervalSince(start)) + run.pausedSeconds)
    }
}
