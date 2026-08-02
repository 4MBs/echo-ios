import SwiftUI

/// One card: where it came from, what it asks, and the answer.
///
/// The question is the biggest thing on the screen and stands on the background
/// rather than inside a box — it is the content, not a component. The answer
/// controls sit at the bottom edge, in the same place on every card, so the hand
/// does not have to look for them.
///
/// Two interactions for a multiple-choice card (answer, next) and three for a
/// written one (write, reveal, rate). The screen this replaces asked for five,
/// including a three-way confidence picker before every single answer whose
/// value was never shown to anybody again.
struct QuestionView: View {
    let card: BackendAPI.LearnCard
    let lesson: BackendAPI.LessonInfo?
    let api: BackendAPI
    let width: CGFloat
    let isLast: Bool
    /// correct, rating 0…3, milliseconds taken, confidence when the student
    /// judged the answer themselves.
    let onAnswer: (Bool, Int, Int, Int?) -> Void
    let onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var selected: Int?
    @State private var typed = ""
    @State private var revealed = false
    @State private var rated = false
    @State private var playingSource = false
    @State private var startedAt = Date()
    @FocusState private var writing: Bool

    /// A card is a choice when it has options to choose from. The kind alone is
    /// not enough: an older card carries no kind at all, and a generator that
    /// wrote none would otherwise leave a screen with nothing to answer.
    private var isChoice: Bool {
        guard !card.options.isEmpty, card.options.indices.contains(card.answer) else { return false }
        return card.kind == nil || card.kind == "multiple_choice" || card.kind == "true_false"
    }

    private var isOral: Bool { card.kind == "oral" }
    private var answered: Bool { selected != nil || rated }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                origin
                question
                if isChoice { options }
                if isChoice, answered { verdict }
                if revealed, !isChoice { expectedAnswer }
                if answered || revealed { explanation }
                if answered || revealed { sourceControls }
            }
            .frame(maxWidth: Theme.Width.readable, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.screen)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.section)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { answerBar }
        .animation(reduceMotion ? nil : .snappy, value: selected)
        .animation(reduceMotion ? nil : .snappy, value: revealed)
        .animation(reduceMotion ? nil : .snappy, value: rated)
    }

    // MARK: - The question

    private var origin: some View {
        HStack(spacing: 8) {
            SubjectDot(subject: card.subject)
            Text(originText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var originText: String {
        var parts = [card.subject ?? otherSubjectName]
        if let started = lesson?.startedAt {
            parts.append(LearnDay.short(started))
        } else if let title = card.lessonTitle, !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: " · ")
    }

    private var question: some View {
        Text(card.question)
            .font(width >= Theme.Width.largeQuestion ? .title : .title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: - Choosing

    private var options: some View {
        VStack(spacing: 10) {
            ForEach(Array(card.options.enumerated()), id: \.offset) { index, text in
                Button {
                    choose(index)
                } label: {
                    OptionRow(
                        letter: Self.letter(index),
                        text: text,
                        state: state(of: index)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selected != nil)
                .keyboardShortcut(shortcut(for: index), modifiers: [])
                .accessibilityLabel("\(Self.letter(index)): \(text)")
                .accessibilityAddTraits(selected == index ? [.isSelected] : [])
            }
        }
    }

    private func state(of index: Int) -> OptionRow.Status {
        guard selected != nil else { return .idle }
        if index == card.answer { return .correct }
        if index == selected { return .wrong }
        return .dimmed
    }

    private func choose(_ index: Int) {
        guard selected == nil else { return }
        selected = index
        let correct = index == card.answer
        onAnswer(correct, correct ? 2 : 0, elapsedMs, nil)
        announce(correct ? "Richtig" : "Falsch. Richtig ist \(Self.letter(card.answer)).")
    }

    // MARK: - Writing

    private func reveal() {
        guard !revealed else { return }
        writing = false
        revealed = true
        announce("Antwort aufgedeckt")
    }

    private var stacksControls: Bool {
        width < Theme.Width.narrow || typeSize >= .accessibility1
    }

    private func rate(_ rating: Int) {
        guard !rated else { return }
        rated = true
        onAnswer(rating >= 2, rating, elapsedMs, confidence(for: rating))
    }

    /// Confidence is no longer asked before the answer; it is read off the
    /// judgement the student already made afterwards. The field stays optional
    /// on the wire, and a tapped option sends none at all.
    private func confidence(for rating: Int) -> Int {
        switch rating {
        case ...0: 0
        case 3: 2
        default: 1
        }
    }

    // MARK: - After the answer

    /// A word, a symbol and a colour — never fewer than two of the three.
    ///
    /// Only the chosen path has a verdict. A written answer the student has just
    /// judged themselves does not need to be told what they decided; it gets the
    /// model answer instead.
    private var verdict: some View {
        Label {
            Text(verdictText)
                .font(.headline)
        } icon: {
            Image(systemName: wasCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
        }
        .foregroundStyle(wasCorrect ? Color.green : Color.red)
    }

    private var wasCorrect: Bool { selected == card.answer }

    private var verdictText: String {
        wasCorrect ? "Richtig" : "Falsch — richtig ist \(Self.letter(card.answer))"
    }

    @ViewBuilder
    private var expectedAnswer: some View {
        if let expected = card.expectedAnswer, !expected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("So war es gemeint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(expected)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var explanation: some View {
        if !card.explanation.isEmpty {
            Text(card.explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Back into the lesson

    /// The one thing this app can do that a flashcard app cannot: the twenty
    /// seconds of the lesson the question was written from. It used to be a grey
    /// line of text saying "Quelle: Mathematik · 12:30".
    @ViewBuilder
    private var sourceControls: some View {
        if let start = card.sourceStartMs, hasRecording {
            if playingSource {
                SourceExcerptPlayer(
                    api: api,
                    lessonId: card.sessionId,
                    startMs: start,
                    endMs: card.sourceEndMs
                ) {
                    playingSource = false
                }
            } else {
                Button {
                    playingSource = true
                } label: {
                    Label("Im Unterricht hören", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private var hasRecording: Bool {
        lesson?.hasAudio == true || BackendAPI.cachedAudio(id: card.sessionId) != nil
    }

    // MARK: - The bar that never moves

    /// Nothing to pin while a choice card is still unanswered: the options
    /// themselves are the answer, and an empty grey strip along the bottom edge
    /// is a control that is not there.
    private var showsAnswerBar: Bool { answered || !isChoice }

    @ViewBuilder
    private var answerBar: some View {
        if showsAnswerBar {
            VStack(spacing: Theme.Space.row) {
                if !isChoice, !answered {
                    WrittenAnswerField(
                        isOral: isOral,
                        isLocked: revealed,
                        text: $typed,
                        focus: $writing,
                        onSubmit: reveal
                    )
                    if revealed {
                        RatingControls(stacked: stacksControls, onRate: rate)
                    } else {
                        Button("Antwort zeigen") { reveal() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .keyboardShortcut(.space, modifiers: [])
                            .disabled(!isOral && typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if answered {
                    Button(isLast ? "Fertig" : "Weiter") { onNext() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .frame(maxWidth: Theme.Width.readable)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.screen)
            .padding(.top, Theme.Space.row)
            .padding(.bottom, Theme.Space.row)
            .background(.bar)
        }
    }

    // MARK: - Helpers

    private var elapsedMs: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func shortcut(for index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(min(index + 1, 9))"))
    }

    private static func letter(_ index: Int) -> String {
        guard index >= 0, index < 26 else { return "?" }
        return String(UnicodeScalar(UInt8(65 + index)))
    }
}
