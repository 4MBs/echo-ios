import SwiftUI

/// Multiple-choice quiz over one lesson or a whole day. Questions come from
/// the backend (Gemini, exam-relevant content only) and are generated fresh
/// on every run, so repeating the quiz asks new questions.
struct QuizView: View {
    let api: BackendAPI
    let sessionIds: [String]
    /// Navigation title; nil when embedded (lesson detail's Quiz segment).
    let title: String?

    private enum Phase {
        case idle
        case loading
        case running
        case finished
    }

    @State private var phase: Phase = .idle
    @State private var questions: [BackendAPI.QuizQuestion] = []
    @State private var index = 0
    @State private var selected: Int?
    @State private var score = 0
    @State private var errorMessage: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(QuizContainer(title: title))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            startScreen
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Quiz wird aus dem Unterricht erstellt…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        case .running:
            questionScreen
        case .finished:
            resultScreen
        }
    }

    // MARK: - Start

    private var startScreen: some View {
        VStack(spacing: 18) {
            Text("Verstanden?\nTeste dein Wissen!")
                .font(.headline)
                .multilineTextAlignment(.center)
                .stickyNote(rotation: 1.5)
                .padding(.top, 30)
            Text("Ein Durchgang deckt den kompletten Lernstoff ab —\nabgefragt wird nur, was wichtig ist.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await start() }
            } label: {
                Label("Quiz starten", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private func start() async {
        phase = .loading
        errorMessage = nil
        do {
            questions = try await api.quiz(sessionIds: sessionIds)
            index = 0
            score = 0
            selected = nil
            phase = .running
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    // MARK: - Question

    private var question: BackendAPI.QuizQuestion { questions[index] }

    private var questionScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Frage \(index + 1) von \(questions.count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(score) richtig")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: Double(index), total: Double(questions.count))
                    .tint(Theme.accent)

                Text(question.question)
                    .font(.title3.weight(.semibold))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()

                ForEach(Array(question.options.enumerated()), id: \.offset) { option, text in
                    optionButton(option, text)
                }

                if selected != nil {
                    if !question.explanation.isEmpty {
                        Label(question.explanation, systemImage: "lightbulb.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .paperCard(cornerRadius: 12)
                    }
                    Button {
                        next()
                    } label: {
                        Text(index + 1 < questions.count ? "Weiter" : "Ergebnis anzeigen")
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .animation(.snappy, value: selected)
        }
    }

    private func optionButton(_ option: Int, _ text: String) -> some View {
        Button {
            guard selected == nil else { return }
            selected = option
            if option == question.answer { score += 1 }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: optionIcon(option))
                    .foregroundStyle(optionColor(option))
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                optionColor(option).opacity(selected == nil ? 0 : 0.10),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .paperCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .disabled(selected != nil)
    }

    private func optionIcon(_ option: Int) -> String {
        guard selected != nil else { return "circle" }
        if option == question.answer { return "checkmark.circle.fill" }
        if option == selected { return "xmark.circle.fill" }
        return "circle"
    }

    private func optionColor(_ option: Int) -> Color {
        guard selected != nil else { return .secondary }
        if option == question.answer { return .green }
        if option == selected { return .red }
        return .secondary
    }

    private func next() {
        if index + 1 < questions.count {
            index += 1
            selected = nil
        } else {
            phase = .finished
        }
    }

    // MARK: - Result

    private var resultScreen: some View {
        VStack(spacing: 18) {
            Text(resultEmoji)
                .font(.system(size: 52))
                .padding(.top, 30)
            Text("\(score) von \(questions.count) richtig")
                .font(.title2.weight(.bold))
            Text(resultText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await start() }
            } label: {
                Label("Neues Quiz", systemImage: "arrow.clockwise")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var resultEmoji: String {
        let ratio = Double(score) / Double(max(questions.count, 1))
        if ratio >= 0.9 { return "🏆" }
        if ratio >= 0.6 { return "💪" }
        return "📚"
    }

    private var resultText: String {
        let ratio = Double(score) / Double(max(questions.count, 1))
        if ratio >= 0.9 { return "Stark — du hast den Stoff drauf." }
        if ratio >= 0.6 { return "Gut! Ein paar Themen lohnen noch einen Blick." }
        return "Schau dir die Zusammenfassung nochmal an und versuch es erneut."
    }
}

/// Standalone (day quiz) gets a paper screen + navigation title; embedded
/// (lesson detail segment) renders inline without its own chrome.
private struct QuizContainer: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content
                .paperScreen()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
