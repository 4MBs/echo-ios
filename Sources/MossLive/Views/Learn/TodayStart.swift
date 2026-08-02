import SwiftUI

/// The top of Heute: one line that answers "what now", and the one button that
/// does it.
///
/// Everything the screen exists for is in these two elements, which is why they
/// are a view of their own — the copy for every state a student can open the tab
/// in lives in one place instead of being spread across a page of layout.
struct TodayStart: View {
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
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            action
        }
        .animation(.smooth(duration: 0.3), value: plan.cards.count)
    }

    /// One filled button, or — when there is nothing due — a quiet one, because
    /// a screen that has nothing to demand should not look like it does.
    @ViewBuilder
    private var action: some View {
        if let resumable {
            LearnPrimaryButton("Weiterlernen", action: onResume)
                .accessibilityHint("Setzt die Lernrunde bei Frage \(resumable.position) fort")
        } else if !plan.isEmpty {
            LearnPrimaryButton("Lernen starten", action: onStart)
        } else if hasCards {
            Button("Trotzdem üben", action: onPractise)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private var headline: String {
        if let resumable {
            return "Lernrunde läuft · \(resumable.position) von \(resumable.total)"
        }
        if plan.isEmpty { return hasCards ? "Heute nichts fällig" : "Noch keine Karten" }
        return plan.cards.count == 1 ? "1 Karte fällig" : "\(plan.cards.count) Karten fällig"
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
