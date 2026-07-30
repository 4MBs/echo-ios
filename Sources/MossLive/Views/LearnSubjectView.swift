import SwiftUI

/// One subject on the Lernen dashboard: what is filed under it, and what of that
/// has become cards.
///
/// The grid is built from the timetable rather than from the deck, so a subject
/// has its place before its first recording does. An empty folder is a true
/// statement about the school year; a grid that only showed subjects with cards
/// in them would be a different shape every week.
struct LearnFolder: Identifiable {
    let name: String
    /// The string recordings of this subject are labelled with. `nil` is the
    /// catch-all: everything recorded while no lesson was running.
    let subject: String?
    let lessons: [BackendAPI.LessonInfo]
    let due: Int
    let cardCount: Int

    /// Prefixed out of the way so a real subject actually called "Sonstige"
    /// could still have its own card beside the catch-all.
    var id: String { subject ?? "\u{1}sonstige" }

    /// Which cards belong to this folder.
    var scope: SubjectScope {
        guard let subject else { return .unfiled }
        return .named(subject)
    }

    /// Nothing recorded. The card is still drawn — the subject exists whether or
    /// not it has been recorded — but it does not open, because there is nothing
    /// on the other side that a greyed-out card has not already said.
    var isEmpty: Bool { lessons.isEmpty }
}

/// Which slice of the deck a screen is asking for.
///
/// Three cases and not an optional string, because an optional conflates the two
/// that matter most here: `subject=` omitted asks the server for *every*
/// subject, and a recording with no subject at all is a different set entirely.
/// The old code passed `nil` for both, so opening Sonstige handed you the whole
/// app's deck.
enum SubjectScope: Hashable {
    case everything
    case named(String)
    /// Recorded while no lesson was running — the holidays, an evening, a free
    /// period.
    case unfiled

    /// What to send as `?subject=`. There is deliberately no value for
    /// `.unfiled`: the absence of a subject and the absence of a filter are the
    /// same empty query, so that case never reaches the server at all.
    var query: String? {
        switch self {
        case .everything, .unfiled: nil
        case .named(let name): name
        }
    }

    var isUnfiled: Bool {
        if case .unfiled = self { return true }
        return false
    }
}

/// One lesson's cards, split by whether they are waiting today.
struct LessonDeck {
    let cards: [BackendAPI.LearnCard]
    let due: [BackendAPI.LearnCard]
}

/// Today, spelled the way the server spells a due date.
///
/// Plain `YYYY-MM-DD`, which compares correctly as text — no parsing, and no
/// time zone to get wrong.
enum LearnDay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var today: String { formatter.string(from: Date()) }
}

/// Due, and not already answered on a card whose result is still queued —
/// otherwise the same question comes back around the same afternoon.
func isCardDue(_ card: BackendAPI.LearnCard, today: String, answered: Set<String>) -> Bool {
    card.dueDate <= today && !answered.contains(card.id)
}

/// A deck cut into one pile per lesson, each pile knowing what of it is waiting.
///
/// One walk of the cards for any number of lessons, which is why both screens
/// call this rather than filtering per row.
func lessonDecks(from cards: [BackendAPI.LearnCard], answered: Set<String>) -> [String: LessonDeck] {
    let today = LearnDay.today
    var grouped: [String: [BackendAPI.LearnCard]] = [:]
    for card in cards {
        grouped[card.sessionId, default: []].append(card)
    }
    return grouped.mapValues { deck in
        LessonDeck(cards: deck, due: deck.filter { isCardDue($0, today: today, answered: answered) })
    }
}

/// A subject's recordings, each one a deck to be learned.
///
/// The tab used to go from a subject straight into the questions, which made the
/// whole subject one undifferentiated pile: you could learn "Mathematik", but
/// not Tuesday's lesson on it. A subject is a shelf of lessons, a lesson is the
/// thing that was taught, and the cards belong to the lesson — so that is the
/// order they are opened in.
struct LearnSubjectView: View {
    @Environment(AppModel.self) private var model

    let api: BackendAPI
    let name: String
    let scope: SubjectScope
    let lessons: [BackendAPI.LessonInfo]

    /// This subject's cards, keyed by session id.
    ///
    /// Seeded from the dashboard so the list is right the moment it opens, then
    /// refetched every time it comes back on screen. Without that, returning
    /// from a review that just rescheduled six cards lands on a list still
    /// insisting they are due.
    @State private var decks: [String: LessonDeck]

    init(
        api: BackendAPI,
        name: String,
        scope: SubjectScope,
        lessons: [BackendAPI.LessonInfo],
        decks: [String: LessonDeck]
    ) {
        self.api = api
        self.name = name
        self.scope = scope
        self.lessons = lessons
        _decks = State(initialValue: decks)
    }

    var body: some View {
        List {
            Section {
                ForEach(lessons) { lesson in
                    NavigationLink {
                        destination(for: lesson)
                    } label: {
                        row(lesson)
                    }
                    // A lesson with no deck needs one written, and writing it is
                    // the AI's job on the server.
                    .disabled(decks[lesson.id] == nil && !model.connectivity.isOnline)
                }
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .onAppear { Task { await refresh() } }
    }

    /// The subject's cards, straight from the server.
    ///
    /// Silent on failure: what the dashboard handed over is still the best
    /// answer there is, and an error over a list that reads correctly would be
    /// noise. Sonstige is filtered here rather than asked for, because there is
    /// no query for the absence of a subject.
    private func refresh() async {
        guard let fetched = try? await api.allCards(subject: scope.query) else { return }
        let mine = scope.isUnfiled ? fetched.filter { $0.subject == nil } : fetched
        decks = lessonDecks(from: mine, answered: model.reviews.answeredIDs)
    }

    // MARK: - Rows

    private func row(_ lesson: BackendAPI.LessonInfo) -> some View {
        HStack(spacing: 12) {
            LessonRow(info: lesson)
            trailing(decks[lesson.id])
        }
    }

    /// What this lesson is worth opening for: the number waiting, the size of a
    /// deck with nothing due, or a plus where there is no deck at all.
    @ViewBuilder
    private func trailing(_ deck: LessonDeck?) -> some View {
        if let deck, !deck.due.isEmpty {
            Text("\(deck.due.count)")
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.accent, in: Capsule())
                .accessibilityLabel("\(deck.due.count) fällig")
        } else if let deck {
            Text("\(deck.cards.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(deck.cards.count) Karten, nichts fällig")
        } else {
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Kartensatz erstellen")
        }
    }

    // MARK: - Where a lesson leads

    /// Due cards if any are due, the whole deck as practice if not, and a fresh
    /// deck the first time — practice rather than review on a learned lesson, so
    /// going back over Tuesday does not push Tuesday's cards up the ladder for
    /// having been answered a second time.
    @ViewBuilder
    private func destination(for lesson: BackendAPI.LessonInfo) -> some View {
        let title = lesson.startedAt.formatted(date: .abbreviated, time: .shortened)
        let deck = decks[lesson.id]
        if let deck, !deck.due.isEmpty {
            ReviewView(api: api, title: title, mode: .review) { deck.due }
        } else if let deck, !deck.cards.isEmpty {
            ReviewView(api: api, title: "\(title) üben", mode: .practice) { deck.cards }
        } else {
            ReviewView(api: api, title: title, mode: .review) {
                try await api.generateCards(sessionId: lesson.id)
            }
        }
    }

    private var footer: String {
        guard lessons.contains(where: { decks[$0.id] == nil }) else {
            return "Tippe eine Stunde an, um ihre Karten zu lernen."
        }
        return model.connectivity.isOnline
            ? "Stunden mit + haben noch keinen Kartensatz. Beim ersten Öffnen schreibt ihn die KI."
            : "Neue Kartensätze schreibt die KI auf dem Server — dafür wird eine Verbindung gebraucht."
    }
}
