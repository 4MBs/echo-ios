import SwiftUI

/// Plays one review or practice session over a set of spaced-repetition
/// cards. In review mode every answer is reported to the server, which
/// reschedules the card (richtig → Leiter hoch, falsch → morgen wieder);
/// practice mode never touches the schedule.
struct ReviewView: View {
    enum Mode {
        case review
        case practice
        case exam

        var apiName: String {
            switch self {
            case .review: "review"
            case .practice: "practice"
            case .exam: "exam"
            }
        }
    }

    let api: BackendAPI
    let title: String
    let mode: Mode
    /// Fetches the session's cards (due cards, a whole deck, or a freshly
    /// generated one) — runs once when the screen appears.
    let loader: () async throws -> [BackendAPI.LearnCard]

    private enum Phase {
        case loading
        case running
        case finished
        case failed(Error)
    }

    @Environment(AppModel.self) private var model
    @State private var phase: Phase = .loading
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var index = 0
    @State private var selected: Int?
    @State private var score = 0
    @State private var typedAnswer = ""
    @State private var revealed = false
    @State private var answerComplete = false
    @State private var confidence = 1
    @State private var questionStartedAt = Date()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .groupedScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Karten werden geladen…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        case .running:
            questionScreen
        case .finished:
            resultScreen
        case .failed(let error):
            ErrorState(error) { await start() }
        }
    }

    private func start() async {
        phase = .loading
        do {
            let loaded = try await loader()
            guard !loaded.isEmpty else {
                phase = .failed(BackendAPI.APIError(message: "Keine Karten gefunden."))
                return
            }
            cards = loaded
            index = 0
            score = 0
            selected = nil
            typedAnswer = ""
            revealed = false
            answerComplete = false
            confidence = 1
            questionStartedAt = Date()
            phase = .running
        } catch {
            phase = .failed(error)
        }
    }

    // MARK: - Question

    private var card: BackendAPI.LearnCard { cards[index] }

    private var questionScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Frage \(index + 1) von \(cards.count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(score) richtig")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: Double(index), total: Double(cards.count))

                if let origin = card.lessonTitle ?? card.subject {
                    Text(origin)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(card.question)
                    .font(.title3.weight(.semibold))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()

                confidencePicker

                if isChoice {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { option, text in
                        optionButton(option, text)
                    }
                } else {
                    constructedAnswer
                }

                if selected != nil || revealed {
                    if let expected = card.expectedAnswer, !isChoice {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Musterantwort")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(expected)
                                .font(.body.weight(.medium))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface(cornerRadius: 12)
                    }
                    if !card.explanation.isEmpty {
                        Label(card.explanation, systemImage: "lightbulb.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(cornerRadius: 12)
                    }
                    if mode == .review, answerComplete, selected != nil, selected != card.answer {
                        Label("Diese Karte kommt morgen wieder.", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if revealed, !isChoice, !answerComplete {
                        ratingButtons
                    }
                    if answerComplete {
                        Button {
                            next()
                        } label: {
                            Text(index + 1 < cards.count ? "Weiter" : "Ergebnis anzeigen")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    }
                }

                if let source = card.sourceLabel ?? card.lessonTitle {
                    Label(sourceDescription(source), systemImage: "quote.opening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
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
            let correct = option == card.answer
            if correct { score += 1 }
            answerComplete = true
            record(correct: correct, rating: correct ? 2 : 0)
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
            .cardSurface(cornerRadius: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(optionColor(option).opacity(selected == nil ? 0 : 0.10))
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .disabled(selected != nil)
    }

    private var isChoice: Bool {
        card.kind == nil || card.kind == "multiple_choice" || card.kind == "true_false"
    }

    private var confidencePicker: some View {
        Picker("Wie sicher bist du?", selection: $confidence) {
            Text("Unsicher").tag(0)
            Text("Mittel").tag(1)
            Text("Sicher").tag(2)
        }
        .pickerStyle(.segmented)
        .disabled(selected != nil || revealed)
        .accessibilityLabel("Sicherheit vor der Antwort")
    }

    private var constructedAnswer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.kind == "oral" {
                Label("Antworte laut und vergleiche danach.", systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Deine Antwort", text: $typedAnswer, axis: .vertical)
                    .lineLimit(3 ... 7)
                    .textFieldStyle(.roundedBorder)
                    .disabled(revealed)
            }
            Button(revealed ? "Antwort aufgedeckt" : "Mit Musterantwort vergleichen") {
                revealed = true
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(revealed ||
                (card.kind != "oral" && typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    private var ratingButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wie gut war deine Antwort?")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ratingButton("Nicht gewusst", rating: 0, color: .red)
                ratingButton("Schwer", rating: 1, color: .orange)
                ratingButton("Gut", rating: 2, color: .blue)
                ratingButton("Sicher", rating: 3, color: .green)
            }
        }
    }

    private func ratingButton(_ title: String, rating: Int, color: Color) -> some View {
        Button(title) {
            let correct = rating >= 2
            if correct { score += 1 }
            answerComplete = true
            record(correct: correct, rating: rating)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(color)
        .frame(maxWidth: .infinity)
    }

    private func record(correct: Bool, rating: Int) {
        guard mode != .practice else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(questionStartedAt) * 1000))
        let cardId = card.id
        let modeName = mode.apiName
        let answerConfidence = confidence
        Task {
            await model.reviews.record(
                cardId: cardId,
                correct: correct,
                rating: rating,
                responseMs: elapsed,
                confidence: answerConfidence,
                mode: modeName,
                api: api
            )
        }
    }

    private func sourceDescription(_ source: String) -> String {
        guard let milliseconds = card.sourceStartMs else { return "Quelle: \(source)" }
        let seconds = max(0, Int(milliseconds / 1000))
        return "Quelle: \(source) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func optionIcon(_ option: Int) -> String {
        guard selected != nil else { return "circle" }
        if option == card.answer { return "checkmark.circle.fill" }
        if option == selected { return "xmark.circle.fill" }
        return "circle"
    }

    private func optionColor(_ option: Int) -> Color {
        guard selected != nil else { return .secondary }
        if option == card.answer { return .green }
        if option == selected { return .red }
        return .secondary
    }

    private func next() {
        if index + 1 < cards.count {
            index += 1
            selected = nil
            typedAnswer = ""
            revealed = false
            answerComplete = false
            confidence = 1
            questionStartedAt = Date()
        } else {
            phase = .finished
        }
    }

    // MARK: - Result

    private var resultScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: resultSymbol)
                .font(.system(size: 56))
                .foregroundStyle(resultColor)
                .padding(.top, 30)
            Text("\(score) von \(cards.count) richtig")
                .font(.title2.weight(.bold))
            Text(resultText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var resultSymbol: String {
        let ratio = Double(score) / Double(max(cards.count, 1))
        if ratio >= 0.9 { return "trophy.fill" }
        if ratio >= 0.6 { return "hand.thumbsup.fill" }
        return "lightbulb.fill"
    }

    private var resultColor: Color {
        let ratio = Double(score) / Double(max(cards.count, 1))
        if ratio >= 0.9 { return .yellow }
        if ratio >= 0.6 { return .green }
        return .orange
    }

    private var resultText: String {
        let wrong = cards.count - score
        switch mode {
        case .review where wrong == 0:
            return "Stark, alles gewusst!\nDie Karten kommen in größeren Abständen wieder."
        case .review:
            return wrong == 1
                ? "1 Karte kommt morgen wieder dran."
                : "\(wrong) Karten kommen morgen wieder dran."
        case .practice:
            return "Übung beeinflusst den Lernplan nicht.\nFällige Karten bleiben fällig."
        case .exam:
            return "Die Probe-Arbeit ist beendet.\nUnsichere Themen werden im nächsten Tagesplan priorisiert."
        }
    }
}
