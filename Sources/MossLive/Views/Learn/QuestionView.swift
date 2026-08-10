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
    /// Whether answers change the schedule, which is the only thing that makes
    /// "kommt morgen wieder" true or false.
    let countsForPlan: Bool
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
    @State private var lastRating = 2
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
                question
                if isChoice { options }
                if answered || revealed { aftermath }
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
        // The system's own answer to "did that register" — the same feedback a
        // correct or a rejected entry gets everywhere else in iOS.
        .sensoryFeedback(trigger: selected) { _, new in
            guard let new else { return nil }
            return new == card.answer ? .success : .error
        }
    }

    // MARK: - The question

    /// The largest thing on the screen, on the background rather than in a box.
    /// Where it came from is in the header — it is true of the whole screen, not
    /// of this paragraph.
    private var question: some View {
        Text(card.question)
            .font(width >= Theme.Width.largeQuestion ? .title : .title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Everything the answer produced, in one block so it arrives as one move:
    /// the verdict, what the card was after, why, what happens to it next, and
    /// the two ways back into the lesson it came from.
    private var aftermath: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inset) {
            if isChoice, answered { verdict }
            if revealed, !isChoice { expectedAnswer }
            explanation
            if answered { scheduleNote }
            CardSourceActions(api: api, card: card, lesson: lesson)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the answer did to the card. The schedule lives on the server, so
    /// this says what is certain — a missed card comes back tomorrow, a known
    /// one waits longer — and never invents a number of days.
    @ViewBuilder
    private var scheduleNote: some View {
        if let text = scheduleText {
            Label(text, systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Practice says nothing here: it changes nothing, and repeating that on
    /// twenty cards in a row is noise. The result screen says it once.
    private var scheduleText: String? {
        guard countsForPlan else { return nil }
        if isChoice { return selected == card.answer ? "Kommt später wieder." : "Kommt morgen wieder." }
        return lastRating >= 2 ? "Kommt später wieder." : "Kommt morgen wieder."
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
        lastRating = rating
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
