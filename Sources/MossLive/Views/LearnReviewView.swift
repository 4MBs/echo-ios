import SwiftUI

struct LearnReviewView: View {
    let api: BackendAPI
    let mode: String
    let onChanged: (() async -> Void)?
    @State private var session: LearnReviewSession
    @State private var answer = ""
    @State private var evaluation: BackendAPI.LearnEvaluation?
    @State private var remediation: BackendAPI.LearnRemediation?
    @State private var isEvaluating = false
    @State private var errorMessage: String?
    @State private var confidence: Int?
    @State private var questionStartedAt = Date()
    @FocusState private var answerFocused: Bool

    init(
        api: BackendAPI,
        cards: [BackendAPI.LearnCard],
        mode: String = "review",
        onChanged: (() async -> Void)? = nil
    ) {
        self.api = api
        self.mode = mode
        self.onChanged = onChanged
        _session = State(initialValue: LearnReviewSession(cards: cards))
    }

    var body: some View {
        Group {
            if session.isComplete {
                ContentUnavailableView {
                    Label("Wiederholung geschafft", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("Du hast \(session.completedCount) Konzepte aktiv abgerufen.")
                }
            } else if let card = session.currentCard {
                review(card)
            }
        }
        .navigationTitle("Wiederholen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func review(_ card: BackendAPI.LearnCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(card.subject ?? "Lernkonzept")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text("\(session.completedCount + 1) / \(session.cards.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: session.progress)

                Text(card.question)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if card.workedExampleStage == 0, evaluation == nil, remediation == nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Durchgerechnetes Beispiel", systemImage: "function")
                            .font(.headline).foregroundStyle(Theme.accent)
                        Text(card.explanation)
                        if let expected = card.expectedAnswer, !expected.isEmpty { Text(expected) }
                        Text("Das Ansehen allein zählt noch nicht als gelernt. Danach folgen Lückenschritt und Transferaufgabe.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Beispiel verstanden – weiter") { Task { await finishStudyExample(card) } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let remediation {
                    LearnRemediationView(api: api, card: card, remediation: remediation) {
                        advance()
                    }
                } else if let evaluation {
                    feedback(evaluation, card: card)
                } else {
                    LearnAnswerSpecView(spec: card.answerSpec, answer: $answer)
                        .focused($answerFocused)
                    Picker("Wie sicher bist du?", selection: $confidence) {
                        Text("Nicht angegeben").tag(Int?.none)
                        Text("Unsicher").tag(Int?.some(1))
                        Text("Teilweise sicher").tag(Int?.some(2))
                        Text("Sehr sicher").tag(Int?.some(4))
                    }
                    Button {
                        Task { await evaluate(card) }
                    } label: {
                        if isEvaluating {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Antwort prüfen").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEvaluating)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { answerFocused = true }
    }

    private func feedback(_ evaluation: BackendAPI.LearnEvaluation, card: BackendAPI.LearnCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(evaluation.category.title, systemImage: evaluation.category.systemImage)
                .font(.title3.bold())
                .foregroundStyle(evaluation.category.tint)
            Text(evaluation.feedback)
            VStack(alignment: .leading, spacing: 6) {
                Text("Musterantwort").font(.caption).foregroundStyle(.secondary)
                Text(evaluation.correctAnswer)
            }
            if let source = card.primarySource {
                NavigationLink {
                    LearnSourceView(source: source)
                } label: {
                    Label("Quelle öffnen", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)
            }
            Button(session.completedCount + 1 == session.cards.count ? "Abschließen" : "Nächste Frage") {
                advance()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func evaluate(_ card: BackendAPI.LearnCard) async {
        isEvaluating = true
        errorMessage = nil
        do {
            let duration = max(0, Int(Date().timeIntervalSince(questionStartedAt) * 1_000))
            let result = try await api.evaluateLearnAnswer(
                cardId: card.id, answer: answer, confidence: confidence,
                responseDurationMs: duration,
                mode: mode
            )
            evaluation = result.evaluation
            remediation = result.remediation
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isEvaluating = false
    }

    private func advance() {
        session.advance()
        answer = ""
        evaluation = nil
        remediation = nil
        confidence = nil
        questionStartedAt = Date()
        if session.isComplete, let onChanged { Task { await onChanged() } }
        errorMessage = nil
        answerFocused = true
    }

    private func finishStudyExample(_ card: BackendAPI.LearnCard) async {
        do {
            _ = try await api.updateLearnCard(id: card.id, changes: ["learning_state": "suspended"])
            advance()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension BackendAPI.LearnEvaluation.Category {
    var title: String {
        switch self {
        case .correct: "Richtig"
        case .partial: "Teilweise richtig"
        case .incorrect: "Noch nicht richtig"
        case .misconception: "Missverständnis erkannt"
        }
    }

    var systemImage: String {
        switch self {
        case .correct: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .incorrect: "xmark.circle.fill"
        case .misconception: "exclamationmark.bubble.fill"
        }
    }

    var tint: Color {
        switch self {
        case .correct: .green
        case .partial: .orange
        case .incorrect, .misconception: .red
        }
    }
}

struct LearnSourceView: View {
    @Environment(AppModel.self) private var model
    let source: BackendAPI.LearnSource
    @State private var detail: BackendAPI.LessonDetail?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                List {
                    Section {
                        LabeledContent("Stunde", value: source.lessonTitle ?? detail.title ?? "Unterrichtsstunde")
                        LabeledContent("Zeit", value: timestamp(source.timeSeconds))
                    }
                    Section("Erklärung im Transkript") {
                        ForEach(relevantSegments(detail.segments)) { segment in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(timestamp(segment.t0))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(segment.text)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Quelle nicht verfügbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Quelle wird geladen …")
            }
        }
        .navigationTitle("Erklärung aus der Stunde")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        let key = OfflineCache.Key.lesson(source.sessionId)
        if let stored = OfflineCache.load(BackendAPI.LessonDetail.self, key: key) {
            detail = stored
        }
        do {
            let loaded = try await model.api.lesson(id: source.sessionId)
            detail = loaded
            OfflineCache.save(loaded, as: key)
        } catch is CancellationError {
            return
        } catch {
            if detail == nil { errorMessage = error.localizedDescription }
        }
    }

    private func relevantSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let start = max(0, source.timeSeconds - 12)
        let end = source.timeSeconds + 35
        let matches = segments.filter { $0.t1 >= start && $0.t0 <= end }
        return matches.isEmpty ? Array(segments.prefix(5)) : matches
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
