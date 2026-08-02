import SwiftUI

/// The end of a round: what happened, what follows from it, and what to do next.
///
/// No trophy, no confetti, no colour that grades the student. The two facts that
/// matter are the count and the consequence — which cards come back, and when.
/// Under them the ones that were missed, each opening to show the question and
/// the explanation again without asking for another answer.
struct SessionResultView: View {
    let session: StudySession
    /// A follow-up round, or nothing at all when the student is done.
    let onFinish: (StudySession?) -> Void

    @State private var expanded: Set<String> = []

    private var missed: [BackendAPI.LearnCard] { session.missedCards }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                summary
                if !missed.isEmpty { missedSection }
                actions
            }
            .frame(maxWidth: Theme.Width.readable, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.screen)
            .padding(.vertical, Theme.Space.section)
        }
    }

    /// The count, the proportion, and what follows from it — in that order,
    /// because that is the order the three questions are asked in.
    ///
    /// One surface rather than three loose lines, and no grade: no trophy, no
    /// confetti, no colour that judges the student. The bar is the only place
    /// green and red appear, and both piles are written out beside it.
    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inset) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fertig")
                    .font(.title.weight(.bold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(session.correctCount)")
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                    Text("von \(session.total) richtig")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            OutcomeBar(correct: session.correctCount, wrong: session.total - session.correctCount)

            Text(consequence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.inset + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .learnSurface()
        .accessibilityElement(children: .combine)
    }

    /// What the answers changed. In practice they changed nothing, and saying so
    /// is the whole difference between practice and review.
    private var consequence: String {
        switch session.mode {
        case .practice:
            return "Übung zählt nicht für den Lernplan."
        case .review, .exam:
            let wrong = missed.count
            let counted = session.mode == .exam ? " Die Probe zählt für deinen Lernplan." : ""
            if wrong == 0 { return "Alles gewusst. Die Karten kommen in größeren Abständen wieder." + counted }
            return (wrong == 1
                ? "1 Karte kommt morgen wieder."
                : "\(wrong) Karten kommen morgen wieder.") + counted
        }
    }

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            LearnSectionHeader("Das saß noch nicht")
            LearnRowGroup {
                ForEach(Array(missed.enumerated()), id: \.element.id) { index, card in
                    Button {
                        toggle(card.id)
                    } label: {
                        MissedRow(card: card, isOpen: expanded.contains(card.id))
                    }
                    .buttonStyle(LearnRowButtonStyle())
                    if index < missed.count - 1 { LearnRowDivider() }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.inset) {
            LearnPrimaryButton("Fertig") { onFinish(nil) }
                // Return closes the round, so a round begun on a keyboard can be
                // finished on one.
                .keyboardShortcut(.return, modifiers: [])
            if !missed.isEmpty {
                Button(missed.count == 1 ? "Die eine noch mal" : "Die \(missed.count) noch mal") {
                    onFinish(StudySession(mode: .practice, title: "Noch mal", cards: missed))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

/// A missed card, closed to one line and opened to the answer.
private struct MissedRow: View {
    let card: BackendAPI.LearnCard
    let isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Theme.Space.row) {
                SubjectGlyph(subject: card.subject, size: 26)
                Text(card.question)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isOpen ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if isOpen {
                if let answer = correctAnswer {
                    Text(answer)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !card.explanation.isEmpty {
                    Text(card.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isOpen ? "Antwort ausblenden" : "Antwort anzeigen")
    }

    private var correctAnswer: String? {
        if card.options.indices.contains(card.answer) { return card.options[card.answer] }
        return card.expectedAnswer
    }
}
