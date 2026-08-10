import Foundation
import Observation

/// Everything Heute needs, stored on the iPad and refreshed when there is a
/// server.
///
/// Three requests per opening — the plan, the deck, the exams — and all three
/// have a written-down answer to fall back on. The screen this replaces fired
/// five parallel requests, held a full-screen spinner until the last of them
/// landed and showed a full-screen error if any failed, with no cache at all;
/// on a train the Lernen tab was a blank page while every card needed for it
/// was already on the device.
@MainActor
@Observable
final class LearnStore {
    private(set) var cards: [BackendAPI.LearnCard] = []
    private(set) var exams: [BackendAPI.LearnExam] = []
    /// The archive, from the cache only. Heute never fetches it — the exam sheet
    /// and the exam page do, because they are the two places that need lesson
    /// titles and dates.
    private(set) var lessons: [BackendAPI.LessonInfo] = []
    private(set) var serverPlan: BackendAPI.LearnDailyPlan?

    private(set) var isLoading = false
    /// Set only when there is nothing stored to show instead.
    private(set) var failure: Error?
    /// The exams request failed and there is no stored copy: the section is left
    /// out and the footer says why, rather than the whole screen failing.
    private(set) var examsUnavailable = false
    /// When the stored copy was written, for the footer's "Stand von …".
    private(set) var storedAt: Date?
    private(set) var hasLoadedFromServer = false
    /// Whether the stored copy has been read yet. Before that the screen knows
    /// nothing — which is a skeleton, not an empty state. Without this the first
    /// frame of a device with a full deck says "Hier entstehen deine Karten".
    private(set) var hasReadCache = false

    /// Whether there is anything at all worth drawing — the difference between
    /// a skeleton and a screen.
    var hasContent: Bool { !cards.isEmpty || serverPlan != nil || !exams.isEmpty }

    /// Every subject the deck knows about, in the order a menu should list them.
    var subjectsWithCards: [String] {
        var seen = Set<String>()
        return cards
            .map { $0.subject ?? otherSubjectName }
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Reading what is stored

    /// Instant, synchronous, and enough to draw the whole screen. Called before
    /// the first request so Heute renders from the deck rather than from a
    /// spinner.
    func primeFromCache() {
        defer { hasReadCache = true }
        guard !hasContent else { return }
        cards = storedLearnCards()
        exams = OfflineCache.load([BackendAPI.LearnExam].self, key: OfflineCache.Key.learnExams) ?? []
        serverPlan = OfflineCache.load(BackendAPI.LearnDailyPlan.self, key: OfflineCache.Key.learnPlan)
        lessons = OfflineCache.load([BackendAPI.LessonInfo].self, key: OfflineCache.Key.lessons) ?? []
        storedAt = OfflineCache.savedAt(key: OfflineCache.Key.learnCards)
    }

    // MARK: - Asking the server

    func refresh(api: BackendAPI, minutes: Int, answered: Set<String>) async {
        isLoading = true
        defer { isLoading = false }

        async let planned = api.learnPlan(minutes: minutes)
        async let deck = api.allCards()
        async let scheduled = api.learnExams()

        var firstFailure: Error?

        do {
            let fetched = try await deck
            cards = fetched
            OfflineCache.save(fetched, as: OfflineCache.Key.learnCards)
            storedAt = Date()
            hasLoadedFromServer = true
        } catch {
            firstFailure = error
        }

        do {
            let fetched = try await planned
            serverPlan = fetched
            OfflineCache.save(fetched, as: OfflineCache.Key.learnPlan)
            hasLoadedFromServer = true
        } catch {
            if firstFailure == nil { firstFailure = error }
        }

        do {
            let fetched = try await scheduled
            exams = fetched
            examsUnavailable = false
            OfflineCache.save(fetched, as: OfflineCache.Key.learnExams)
        } catch {
            examsUnavailable = exams.isEmpty
            if firstFailure == nil { firstFailure = error }
        }

        // An error only reaches the screen when there is nothing to put in its
        // place. With a stored deck it is a line in the footer, not a page.
        failure = hasContent ? nil : firstFailure
    }

    /// The archive, for the screens that need lesson titles. Cheap and silent:
    /// what is stored is already the right answer, so a failure changes nothing.
    func refreshLessons(api: BackendAPI) async {
        guard let fetched = try? await api.listLessons() else { return }
        let usable = fetched.filter { $0.segmentCount > 0 }
        lessons = usable
        OfflineCache.save(usable, as: OfflineCache.Key.lessons)
    }

    // MARK: - What today's round is

    /// The server's plan while it is today's, the locally derived one otherwise.
    func plan(minutes: Int, answered: Set<String>) -> StudyPlan {
        if let serverPlan, serverPlan.date == LearnDay.today {
            let plan = StudyPlan.server(serverPlan, answered: answered)
            if !plan.isEmpty { return plan }
        }
        return StudyPlan.local(cards: cards, answered: answered, minutes: minutes, exams: exams)
    }

    /// The next day anything falls due, for the evening when nothing does.
    func nextDueDate(answered: Set<String>) -> Date? {
        let today = LearnDay.today
        let upcoming = cards
            .filter { $0.dueDate > today && !answered.contains($0.id) }
            .map(\.dueDate)
            .min()
        return LearnDay.date(upcoming)
    }

    /// Exams still ahead, soonest first.
    var upcomingExams: [BackendAPI.LearnExam] {
        exams.filter { $0.daysRemaining >= 0 }.sorted { $0.examDate < $1.examDate }
    }

    /// The cards of one exam's material.
    ///
    /// Named `deck` rather than `cards(for:)`: a method that shares its base
    /// name with a stored property shadows it inside its own body.
    func deck(for exam: BackendAPI.LearnExam) -> [BackendAPI.LearnCard] {
        let sessions = Set(exam.sessionIds)
        return cards.filter { sessions.contains($0.sessionId) }
    }

    // MARK: - Local edits

    func remove(examID: String) {
        exams.removeAll { $0.id == examID }
        OfflineCache.save(exams, as: OfflineCache.Key.learnExams)
    }

    func replace(_ exam: BackendAPI.LearnExam) {
        if let index = exams.firstIndex(where: { $0.id == exam.id }) {
            exams[index] = exam
        } else {
            exams.append(exam)
        }
        OfflineCache.save(exams, as: OfflineCache.Key.learnExams)
    }
}
