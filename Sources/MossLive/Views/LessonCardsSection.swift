import SwiftUI

/// What a lesson has become: its cards, and one way to start them.
///
/// This is the reason the Lernen tab no longer needs a second subject grid, a
/// second kind of tile and a second subject screen. A lesson is where its cards
/// belong, and the only two things worth doing with them here are learning what
/// is due and — the first time — having them written.
///
/// It lives with the lesson page rather than with the Lernen area, and takes
/// that page's card metrics (20pt, `cardSurface`) rather than the study tokens:
/// it is a section of Stunden that starts a round, not a piece of Lernen that
/// happens to be displayed here.
struct LessonCardsSection: View {
    let api: BackendAPI
    let lesson: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model

    @State private var deck: LessonDeck?
    /// Held so the state the screen draws from is set before the work starts —
    /// a flag derived from the task handle would depend on the assignment
    /// winning a race against the task's first suspension.
    @State private var isWriting = false
    @State private var writeTask: Task<Void, Never>?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
        .task { await load() }
        // The count is stale the moment a round ends, so it is fetched again
        // when the round's modal closes rather than on the next visit.
        .onChange(of: model.studySession == nil) { _, ended in
            if ended { Task { await load() } }
        }
        .onDisappear { writeTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Karten")
                .font(.headline)
            Spacer(minLength: 0)
            if let deck, !deck.cards.isEmpty {
                Text(countText(deck))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isWriting {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Die Fragen zu dieser Stunde werden geschrieben. Das dauert bis zu einer Minute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Abbrechen") {
                    writeTask?.cancel()
                    writeTask = nil
                    isWriting = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if let deck, !deck.cards.isEmpty {
            Button(deck.due.isEmpty ? "Üben" : "Lernen starten") { start(deck) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.connectivity.isOnline
                    ? "Für diese Stunde gibt es noch keine Karten."
                    : "Für diese Stunde gibt es noch keine Karten. Dafür wird der Server gebraucht.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Karten schreiben") { write() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(!model.connectivity.isOnline)
            }
        }
        if let failure {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func countText(_ deck: LessonDeck) -> String {
        let total = deck.cards.count == 1 ? "1 Karte" : "\(deck.cards.count) Karten"
        return deck.due.isEmpty ? total : "\(total) · \(deck.due.count) fällig"
    }

    // MARK: - Actions

    private func start(_ deck: LessonDeck) {
        let title = lesson.topic ?? LearnDay.short(lesson.startedAt)
        if deck.due.isEmpty {
            model.startStudy(StudySession(mode: .practice, title: title, cards: deck.cards))
        } else {
            model.startStudy(StudySession(mode: .review, title: title, cards: deck.due))
        }
    }

    private func write() {
        failure = nil
        isWriting = true
        writeTask = Task {
            defer {
                isWriting = false
                writeTask = nil
            }
            do {
                let cards = try await api.generateCards(sessionId: lesson.id)
                guard !Task.isCancelled else { return }
                apply(cards)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func load() async {
        apply(storedLearnCards().filter { $0.sessionId == lesson.id })
        guard let fetched = try? await api.allCards(subject: lesson.subject) else { return }
        apply(fetched.filter { $0.sessionId == lesson.id })
    }

    private func apply(_ cards: [BackendAPI.LearnCard]) {
        guard !cards.isEmpty else { return }
        deck = lessonDecks(from: cards, answered: model.reviews.answeredIDs)[lesson.id]
    }
}
