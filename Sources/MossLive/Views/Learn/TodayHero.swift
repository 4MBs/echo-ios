import SwiftUI

/// The top of Heute: what today is, how much of it is left, what it is made of,
/// and the one button that starts it.
///
/// This was a sentence and a button floating on the grouped background, under a
/// large navigation title — two headings competing for the same job and nothing
/// holding them together. Every study product worth looking at gives this
/// moment a composed block instead: a set header in Quizlet, a lesson card with
/// its progress ring in the spaced-repetition flows, an activity card in
/// Fitness. So this is one surface with an internal hierarchy — date, count,
/// composition, action — and it is the only place on the screen where a number
/// is set large.
struct TodayHero: View {
    let plan: StudyPlan
    /// A round that was interrupted and is still worth picking up.
    let resumable: StudySession?
    /// Whether there is a deck at all, which is the difference between "nothing
    /// due today" and "nothing yet".
    let hasCards: Bool
    /// When the next repetition falls due, for the evening when none does.
    let nextDue: Date?
    let onResume: () -> Void
    let onStart: () -> Void
    let onPractise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inset) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dateLine)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                headline
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if !plan.blocks.isEmpty, resumable == nil {
                PlanCompositionBar(blocks: plan.blocks)
            }

            action
        }
        .padding(Theme.Space.inset + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .learnSurface()
        .animation(.smooth(duration: 0.3), value: plan.cards.count)
    }

    /// The count, set as a number and a word rather than as a sentence: it is
    /// the one figure the screen exists to deliver, and at a glance a numeral
    /// reads faster than prose.
    @ViewBuilder
    private var headline: some View {
        if let resumable {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Lernrunde läuft")
                    .font(.title.weight(.semibold))
                Text("\(resumable.position) von \(resumable.total)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else if plan.isEmpty {
            Text(hasCards ? "Heute nichts fällig" : "Noch keine Karten")
                .font(.title.weight(.semibold))
        } else {
            // Side by side while both fit, stacked when the type is large
            // enough that they would not — never shrunk to fit, because the
            // count is the one thing on this screen that must stay readable.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    countNumber
                    countWord
                }
                VStack(alignment: .leading, spacing: 0) {
                    countNumber
                    countWord
                }
            }
        }
    }

    private var countNumber: some View {
        Text("\(plan.cards.count)")
            .font(.largeTitle.weight(.bold))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private var countWord: some View {
        Text(plan.cards.count == 1 ? "Karte fällig" : "Karten fällig")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
    }

    /// One filled button, or — when there is nothing due — a quiet one, because
    /// a screen with nothing to demand should not look like it demands.
    @ViewBuilder
    private var action: some View {
        if let resumable {
            HStack(spacing: Theme.Space.row) {
                LearnPrimaryButton("Weiterlernen", action: onResume)
                    .accessibilityHint("Setzt die Lernrunde bei Frage \(resumable.position) fort")
                Spacer(minLength: 0)
            }
        } else if !plan.isEmpty {
            HStack(spacing: Theme.Space.row) {
                LearnPrimaryButton("Lernen starten", action: onStart)
                Spacer(minLength: 0)
            }
        } else if hasCards {
            Button("Trotzdem üben", action: onPractise)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    // MARK: - Words

    /// "Sonntag, 2. August" — what "heute" actually means, so the count above it
    /// is anchored to a day rather than floating.
    private var dateLine: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var detail: String? {
        if resumable != nil { return "Deine bisherigen Antworten sind gespeichert." }
        if plan.isEmpty {
            guard hasCards else { return nil }
            guard let nextDue else { return "Alle Karten sind gelernt." }
            return "Deine nächste Wiederholung ist am \(LearnDay.weekday(nextDue))."
        }
        let time = plan.estimatedMinutes == 1 ? "etwa 1 Minute" : "etwa \(plan.estimatedMinutes) Minuten"
        let names = plan.subjects.prefix(3).joined(separator: ", ")
        return names.isEmpty ? time : "\(time) · \(names)"
    }
}
