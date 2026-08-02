import SwiftUI

/// "Nachfragen": ask about the question you just got wrong, without leaving the
/// round and without explaining the context first.
///
/// Echo already had both halves of this — a chat that can be grounded in one
/// lesson's transcript (`POST /chat` with a `session_id`), and a card that knows
/// which lesson it came from — and no way to put them together. Studying is
/// exactly the moment the question comes up, so it is asked here, about this
/// card, and it is thrown away afterwards: a round is not a conversation to keep
/// and the Chat tab's own thread stays untouched.
struct AskAboutCardSheet: View {
    let api: BackendAPI
    let card: BackendAPI.LearnCard
    let lesson: BackendAPI.LessonInfo?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var writing: Bool

    private struct Turn: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    /// Openers that are worth a tap because they are the three things a student
    /// actually says when a card goes wrong.
    private static let openers = [
        "Erklär mir das einfacher.",
        "Warum ist das so?",
        "Gib mir ein Beispiel.",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.inset) {
                        cardContext
                        ForEach(turns) { turn in
                            bubble(turn)
                                .id(turn.id)
                        }
                        if sending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Denkt nach …")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let failure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: Theme.Width.readable, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.screen)
                }
                .onChange(of: turns.count) { _, _ in
                    guard let last = turns.last else { return }
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .groupedScreen()
            .navigationTitle("Nachfragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - What the question was about

    private var cardContext: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SubjectGlyph(subject: card.subject, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.subject ?? otherSubjectName)
                        .font(.subheadline.weight(.medium))
                    if let origin {
                        Text(origin)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(card.question)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .learnSurface()
        .accessibilityElement(children: .combine)
    }

    private var origin: String? {
        if let started = lesson?.startedAt { return LearnDay.short(started) }
        return card.lessonTitle?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
    }

    private func bubble(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.mine ? "Du" : "Echo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(turn.mine ? AttributedString(turn.text) : renderedMarkdown(turn.text))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Asking

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 10) {
            if turns.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Self.openers, id: \.self) { opener in
                            Button(opener) { send(opener) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screen)
                }
                .scrollIndicators(.hidden)
            }
            HStack(spacing: 10) {
                TextField("Frag zu dieser Karte", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .focused($writing)
                    .onSubmit { send(question) }
                Button {
                    send(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sending || question.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Frage senden")
            }
            .padding(.horizontal, Theme.Space.screen)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        writing = false
        question = ""
        failure = nil
        turns.append(Turn(mine: true, text: trimmed))
        sending = true
        let history = turns.dropLast().map {
            BackendAPI.ChatTurn(role: $0.mine ? "user" : "assistant", text: $0.text)
        }
        // The card itself travels with the first question: the server grounds
        // the answer in the lesson's transcript, and this says which part of it
        // the student is stuck on.
        let grounded = turns.count == 1
            ? "Es geht um diese Frage aus dem Unterricht: „\(card.question)“\n\n\(trimmed)"
            : trimmed
        let client = api
        let sessionId = card.sessionId
        Task {
            defer { sending = false }
            do {
                let answer = try await client.chat(
                    question: grounded,
                    history: Array(history),
                    sessionId: sessionId
                )
                turns.append(Turn(mine: false, text: answer))
            } catch {
                failure = model.connectivity.isOnline
                    ? error.localizedDescription
                    : "Dafür wird der Server gebraucht. Die Karte kannst du trotzdem weiterlernen."
            }
        }
    }
}
