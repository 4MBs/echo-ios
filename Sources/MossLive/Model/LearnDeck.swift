import Foundation

/// Which slice of the deck a screen is asking for.
///
/// Three cases and not an optional string, because an optional conflates the two
/// that matter most here: `subject=` omitted asks the server for *every*
/// subject, and a recording with no subject at all is a different set entirely.
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

    /// Whether a card belongs to this slice.
    func contains(_ card: BackendAPI.LearnCard) -> Bool {
        switch self {
        case .everything: true
        case .named(let name): card.subject == name
        case .unfiled: card.subject == nil
        }
    }
}

/// One lesson's cards, split by whether they are waiting today.
struct LessonDeck {
    let cards: [BackendAPI.LearnCard]
    let due: [BackendAPI.LearnCard]
}

/// Dates, the way the Lernen area writes them: the server's plain `YYYY-MM-DD`
/// on the wire, German words on the screen.
///
/// One place for all of it. The area previously carried three private date
/// enums (`StudyDate`, `StudyGoalDate`, `LearnDay`) with identical formatters
/// and slightly different spellings of the same sentence.
enum LearnDay {
    /// Plain `YYYY-MM-DD`, which compares correctly as text — no parsing, and no
    /// time zone to get wrong.
    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var today: String { iso.string(from: Date()) }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return iso.date(from: value)
    }

    /// "Fr, 14. Aug" — a date short enough to sit at the end of a row.
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Freitag" — the day a student actually names an exam by.
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    /// How far off something is, in the words a sentence wants.
    static func countdown(days: Int) -> String {
        switch days {
        case ..<0: "vorbei"
        case 0: "Heute"
        case 1: "Morgen"
        default: "noch \(days) Tage"
        }
    }
}

/// Due, and not already answered on a card whose result is still queued —
/// otherwise the same question comes back around the same afternoon.
func isCardDue(_ card: BackendAPI.LearnCard, today: String, answered: Set<String>) -> Bool {
    card.dueDate <= today && !answered.contains(card.id)
}

/// A deck cut into one pile per lesson, each pile knowing what of it is waiting.
///
/// One walk of the cards for any number of lessons, which is why every screen
/// calls this rather than filtering per row.
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

/// The deck as it was last written down.
///
/// Cards never change once they are generated, so any screen may read them
/// without asking the server — which is what makes a lesson page, a subject
/// board and a study round work on a train.
func storedLearnCards() -> [BackendAPI.LearnCard] {
    OfflineCache.load([BackendAPI.LearnCard].self, key: OfflineCache.Key.learnCards) ?? []
}
