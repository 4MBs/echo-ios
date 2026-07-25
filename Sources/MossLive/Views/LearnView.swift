import SwiftUI
import UserNotifications

/// "Lernen": the spaced-repetition home. One tap reviews everything due
/// today; below that, per-subject decks and lessons whose deck hasn't been
/// generated yet. The schedule lives on the server (Leitner ladder), but the
/// deck itself is kept here — cards never change once written, so learning is
/// the one thing in the app that has no business needing a network.
struct LearnView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: BackendAPI.LearnOverview?
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var loadError: Error?

    private var api: BackendAPI { model.api }

    /// Dates come off the server as plain `YYYY-MM-DD`, which compares
    /// correctly as text — no parsing, no time zone to get wrong.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Lernen")
        }
    }

    /// Lessons that don't have a card deck yet, newest first.
    private var pendingLessons: [BackendAPI.LessonInfo] {
        let withCards = Set(shownOverview?.sessionsWithCards ?? [])
        return lessons
            .filter { $0.segmentCount > 0 && !withCards.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// What the screen actually shows. With a server that is the server's
    /// answer. Without one it is rebuilt from the stored deck, so the counts
    /// still fall as cards are answered instead of standing still all evening.
    private var shownOverview: BackendAPI.LearnOverview? {
        guard !model.connectivity.isOnline, !cards.isEmpty else { return overview }
        let subjects = Dictionary(grouping: cards, by: \.subject)
            .map { subject, deck in
                BackendAPI.LearnSubject(
                    subject: subject,
                    due: deck.filter(isDue).count,
                    total: deck.count
                )
            }
            .sorted { ($0.subject ?? "") < ($1.subject ?? "") }
        return BackendAPI.LearnOverview(
            dueTotal: cards.filter(isDue).count,
            cardTotal: cards.count,
            subjects: subjects,
            sessionsWithCards: Array(Set(cards.map(\.sessionId)))
        )
    }

    /// Due, and not already answered on a card whose result is still queued —
    /// otherwise the same question comes back around the same afternoon.
    private func isDue(_ card: BackendAPI.LearnCard) -> Bool {
        card.dueDate <= Self.day.string(from: Date()) && !model.reviews.answeredIDs.contains(card.id)
    }

    private func storedCards(subject: String?, dueOnly: Bool) -> [BackendAPI.LearnCard] {
        cards.filter { card in
            guard subject == nil || card.subject == subject else { return false }
            // Practice never touches the schedule, so it may ask anything.
            return dueOnly ? isDue(card) : true
        }
    }

    /// Ask the server, and fall back to the stored deck when it cannot be
    /// reached. Written this way round so a flaky connection degrades instead
    /// of failing, and so the fallback is never used when the server is fine.
    ///
    /// The fallback is taken here rather than inside the closure: this runs
    /// while the view is on screen, and reading the environment from an
    /// escaping closure that outlives the body is not allowed.
    private func loader(subject: String?, dueOnly: Bool) -> () async throws -> [BackendAPI.LearnCard] {
        let client = api
        let stored = storedCards(subject: subject, dueOnly: dueOnly)
        return {
            do {
                return dueOnly
                    ? try await client.dueCards(subject: subject)
                    : try await client.allCards(subject: subject)
            } catch {
                guard !stored.isEmpty else { throw error }
                return stored
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading, shownOverview == nil {
            ProgressView("Lade Lernstand…")
                .groupedScreen()
                .onAppear { Task { await load() } }
        } else if shownOverview == nil, let loadError {
            ErrorState(loadError) { await load() }
                .groupedScreen()
        } else if let overview = shownOverview {
            if overview.cardTotal == 0, pendingLessons.isEmpty {
                ContentUnavailableView {
                    Label("Noch nichts zu lernen", systemImage: "brain.head.profile")
                } description: {
                    Text("Nimm eine Stunde auf, dann erscheinen hier ihre Karten.")
                }
                .groupedScreen()
                .onAppear { Task { await load() } }
            } else {
                List {
                    todaySection(overview)
                    if !overview.subjects.isEmpty {
                        Section("Fächer") {
                            ForEach(overview.subjects) { subject in
                                SubjectRow(
                                    api: api,
                                    subject: subject,
                                    due: loader(subject: subject.subject, dueOnly: true),
                                    practice: loader(subject: subject.subject, dueOnly: false)
                                )
                            }
                        }
                    }
                    if !pendingLessons.isEmpty {
                        pendingSection
                    }
                    if !model.reviews.pending.isEmpty {
                        queuedSection
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
                .onAppear { Task { await load() } }
            }
        }
    }

    // MARK: - Heute lernen

    @ViewBuilder
    private func todaySection(_ overview: BackendAPI.LearnOverview) -> some View {
        if overview.dueTotal > 0 {
            Section {
                NavigationLink {
                    ReviewView(
                        api: api,
                        title: "Heute lernen",
                        mode: .review,
                        loader: loader(subject: nil, dueOnly: true)
                    )
                } label: {
                    HStack(spacing: 12) {
                        IconTile(systemName: "sparkles", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Heute lernen")
                                .font(.body.weight(.semibold))
                            Text(overview.dueTotal == 1
                                ? "1 Karte ist fällig"
                                : "\(overview.dueTotal) Karten sind fällig")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else if overview.cardTotal > 0 {
            Section {
                Label {
                    Text("Für heute alles gelernt!")
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Noch nicht abgefragt

    private var pendingSection: some View {
        Section {
            ForEach(pendingLessons) { lesson in
                pendingRow(lesson)
                    .disabled(!model.connectivity.isOnline)
            }
        } header: {
            Text("Noch nicht abgefragt")
        } footer: {
            // The deck for a lesson has to be written before it can be learned,
            // and writing it is the AI's job on the server.
            Text(model.connectivity.isOnline
                ? "Beim ersten Abfragen entsteht der Kartensatz der Stunde."
                : "Neue Kartensätze schreibt die KI auf dem Server — dafür wird eine Verbindung gebraucht.")
        }
    }

    private func pendingRow(_ lesson: BackendAPI.LessonInfo) -> some View {
        NavigationLink {
            ReviewView(
                api: api,
                title: lesson.title ?? "Stunde abfragen",
                mode: .review
            ) {
                try await api.generateCards(sessionId: lesson.id)
            }
        } label: {
            let style = subjectStyle(for: lesson.subject)
            HStack(spacing: 12) {
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title ?? "Aufnahme")
                    Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Noch nicht übertragen

    /// Answers given offline, waiting for the server. Shown so the count that
    /// does not match the schedule has a visible reason.
    private var queuedSection: some View {
        Section {
            Label {
                Text(model.reviews.pending.count == 1
                    ? "1 Antwort wartet auf den Server"
                    : "\(model.reviews.pending.count) Antworten warten auf den Server")
            } icon: {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } footer: {
            Text("Sie werden übertragen, sobald der Server wieder erreichbar ist.")
        }
    }

    private func load() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let overviewKey = OfflineCache.Key.learnOverview
        let cardsKey = OfflineCache.Key.learnCards
        let lessonsKey = OfflineCache.Key.lessons

        // First time in: everything stored, so the screen is usable before —
        // and without — a reply.
        if overview == nil, cards.isEmpty {
            overview = OfflineCache.load(BackendAPI.LearnOverview.self, key: overviewKey)
            cards = OfflineCache.load([BackendAPI.LearnCard].self, key: cardsKey) ?? []
            lessons = OfflineCache.load([BackendAPI.LessonInfo].self, key: lessonsKey) ?? []
        }
        if shownOverview == nil { loading = true }
        loadError = nil
        do {
            async let remoteOverview = api.learnOverview()
            async let remoteLessons = api.listLessons()
            // The whole deck, not just what is due: it is a few kilobytes of
            // text, and fetching it now is what makes tonight's train work.
            async let remoteCards = api.allCards()
            let (fetchedOverview, fetchedLessons, fetchedCards) =
                try await (remoteOverview, remoteLessons, remoteCards)

            overview = fetchedOverview
            lessons = fetchedLessons.filter { $0.segmentCount > 0 }
            cards = fetchedCards
            OfflineCache.save(fetchedOverview, as: overviewKey)
            OfflineCache.save(lessons, as: lessonsKey)
            OfflineCache.save(fetchedCards, as: cardsKey)
            await model.flushQueuedReviews()
        } catch {
            if shownOverview == nil { loadError = error }
        }
        loading = false
    }
}

/// One subject's deck: tap reviews what's due (or practices the whole deck
/// when nothing is due); "Üben" via swipe or long-press never touches the
/// schedule.
private struct SubjectRow: View {
    let api: BackendAPI
    let subject: BackendAPI.LearnSubject
    let due: () async throws -> [BackendAPI.LearnCard]
    let practice: () async throws -> [BackendAPI.LearnCard]

    private var name: String { subject.subject ?? "Ohne Fach" }

    @State private var practicing = false

    var body: some View {
        NavigationLink {
            if subject.due > 0 {
                ReviewView(api: api, title: name, mode: .review, loader: due)
            } else {
                practiceDestination
            }
        } label: {
            let style = subjectStyle(for: subject.subject)
            HStack(spacing: 12) {
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .badge(subject.due)
        }
        .swipeActions(edge: .trailing) { practiceButton.tint(Theme.accent) }
        .contextMenu { practiceButton }
        .navigationDestination(isPresented: $practicing) { practiceDestination }
    }

    private var practiceButton: some View {
        Button {
            practicing = true
        } label: {
            Label("Üben", systemImage: "arrow.clockwise")
        }
    }

    private var practiceDestination: some View {
        ReviewView(api: api, title: "\(name) üben", mode: .practice, loader: practice)
    }

    private var subtitle: String {
        let total = subject.total == 1 ? "1 Karte" : "\(subject.total) Karten"
        return subject.due == 0 ? "\(total) · Nichts fällig, tippen zum Üben" : total
    }
}

/// Daily "time to review" local notification (repeats every day at the
/// configured time; the system keeps it across launches).
enum LearnReminder {
    static func sync(enabled: Bool, minuteOfDay: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["learn-reminder"])
        guard enabled else { return }
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zeit zum Lernen"
        content.body = "Schau nach, welche Karten heute fällig sind."
        content.sound = .default
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let request = UNNotificationRequest(
            identifier: "learn-reminder",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        try? await center.add(request)
    }
}
