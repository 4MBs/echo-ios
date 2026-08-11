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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var writing: Bool

    private struct Turn: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
        let date = Date()
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
                    VStack(alignment: .leading, spacing: Theme.Conversation.turnSpacing) {
                        cardContext
                        ForEach(turns) { turn in
                            bubble(turn)
                                .id(turn.id)
                        }
                        if sending {
                            HStack(spacing: 8) {
                                ConversationThinkingDots()
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
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in
                    guard let last = turns.last else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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

    @ViewBuilder
    private func bubble(_ turn: Turn) -> some View {
        if turn.mine {
            VStack(alignment: .trailing, spacing: 2) {
                Text(AttributedString(turn.text))
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Conversation.userHorizontalInset)
                    .padding(.vertical, Theme.Conversation.userVerticalInset)
                    .background(
                        Color(.systemBlue),
                        in: RoundedRectangle(
                            cornerRadius: Theme.Conversation.userBubbleRadius,
                            style: .continuous
                        )
                    )
                    .frame(
                        maxWidth: Theme.Width.readable * Theme.Conversation.userBubbleWidth,
                        alignment: .trailing
                    )
                messageMetadata(turn, copyLabel: "Frage kopieren")
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(renderedMarkdown(turn.text))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                messageMetadata(turn, copyLabel: "Antwort kopieren")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func messageMetadata(_ turn: Turn, copyLabel: String) -> some View {
        HStack(spacing: 2) {
            if turn.mine {
                Spacer(minLength: 0)
                messageTimestamp(turn.date)
                CopyFeedbackButton(text: turn.text, accessibilityLabel: copyLabel)
            } else {
                CopyFeedbackButton(text: turn.text, accessibilityLabel: copyLabel)
                messageTimestamp(turn.date)
                Spacer(minLength: 0)
            }
        }
    }

    private func messageTimestamp(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
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
            HStack(alignment: .bottom, spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Kontext: Diese Karte")
                TextField("Frag zu dieser Karte", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 4)
                    .focused($writing)
                    .submitLabel(.send)
                    .onSubmit { send(question) }
                    .padding(.vertical, 9)
                    .frame(minHeight: 44, maxHeight: 96, alignment: .leading)
                sendButton
            }
            .padding(5)
            .floatingComposerSurface(cornerRadius: 28)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    private var sendButton: some View {
        Button {
            send(question)
        } label: {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(ConversationPrimaryButtonStyle())
        .disabled(sending || question.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel("Frage senden")
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
