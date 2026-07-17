import SwiftUI

/// Plays one review or practice session over a set of spaced-repetition
/// cards. In review mode every answer is reported to the server, which
/// reschedules the card (richtig → Leiter hoch, falsch → morgen wieder);
/// practice mode never touches the schedule.
struct ReviewView: View {
    enum Mode {
        case review
        case practice
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
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var index = 0
    @State private var selected: Int?
    @State private var score = 0

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
        case .failed(let message):
            ErrorState(message: message) { await start() }
        }
    }

    private func start() async {
        phase = .loading
        do {
            let loaded = try await loader()
            guard !loaded.isEmpty else {
                phase = .failed("Keine Karten gefunden.")
                return
            }
            cards = loaded
            index = 0
            score = 0
            selected = nil
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
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

                ForEach(Array(card.options.enumerated()), id: \.offset) { option, text in
                    optionButton(option, text)
                }

                if selected != nil {
                    if !card.explanation.isEmpty {
                        Label(card.explanation, systemImage: "lightbulb.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(cornerRadius: 12)
                    }
                    if mode == .review, selected != card.answer {
                        Label("Diese Karte kommt morgen wieder.", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            if mode == .review {
                // fire-and-forget: a lost report only means the card stays due
                let cardId = card.id
                Task { try? await api.reviewCard(id: cardId, correct: correct) }
            }
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
        }
    }
}
