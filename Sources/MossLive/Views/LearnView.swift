import SwiftUI
import UserNotifications

/// "Lernen": the spaced-repetition home, as a dashboard.
///
/// It opens with who it is talking to and the one thing worth doing right now,
/// then a grid of the subjects there are cards for. The schedule lives on the
/// server (Leitner ladder), but the deck itself is kept here — cards never
/// change once written, so learning is the one thing in the app that has no
/// business needing a network.
///
/// This was a list of rows: "Heute lernen", then a subject per line, then the
/// lessons with no deck yet. Everything was the same height and the same
/// weight, so the screen had no answer to the question it exists to answer —
/// *what should I do now*. The header answers it, and the grid is the map.
struct LearnView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: BackendAPI.LearnOverview?
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var loadError: Error?

    private var api: BackendAPI { model.api }

    /// The header's blue. Written out rather than taken from the app tint: this
    /// is a surface with white type on it, and the tint is a colour for small
    /// marks on a light background. The same word, but the two want different
    /// values of it.
    private static let headerTop = Color(hue: 0.635, saturation: 0.70, brightness: 0.93)
    private static let headerBottom = Color(hue: 0.675, saturation: 0.78, brightness: 0.80)
    /// What is written *on* white inside that header — the same hue taken down
    /// far enough to read as text.
    private static let headerInk = Color(hue: 0.655, saturation: 0.82, brightness: 0.62)

    /// Where the header stops stacking and starts sitting side by side. Chosen
    /// off the pill's own width: below this the two of them together are tighter
    /// than either wants to be.
    private static let wideHeaderWidth: CGFloat = 720

    private static let emptyOverview = BackendAPI.LearnOverview(
        dueTotal: 0, cardTotal: 0, subjects: [], sessionsWithCards: []
    )

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
                .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - The screen

    @ViewBuilder
    private var content: some View {
        if loading, shownOverview == nil {
            ProgressView("Lade Lernstand…")
                .groupedScreen()
                .onAppear { Task { await load() } }
        } else if shownOverview == nil, let loadError {
            ErrorState(loadError) { await load() }
                .groupedScreen()
        } else {
            dashboard(shownOverview ?? Self.emptyOverview)
        }
    }

    private func dashboard(_ overview: BackendAPI.LearnOverview) -> some View {
        let waiting = pendingLessons
        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greetingCard(overview, wide: geo.size.width >= Self.wideHeaderWidth)
                    if !overview.subjects.isEmpty {
                        subjectsSection(overview)
                    }
                    if !waiting.isEmpty {
                        pendingSection(waiting)
                    }
                    if overview.cardTotal == 0, waiting.isEmpty {
                        emptyCard
                    }
                    if !model.reviews.pending.isEmpty {
                        queuedNote
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 36)
                .animation(.smooth(duration: 0.3), value: overview)
            }
            .refreshable { await load() }
        }
        .groupedScreen()
        .onAppear { Task { await load() } }
    }

    // MARK: - The greeting

    /// The header: a sentence addressed to someone, and under it the single
    /// control that starts the day's work.
    ///
    /// The card the design came from carried a search field here. Search is not
    /// what this screen is for — there are a dozen subjects, all of them on
    /// screen at once — so the white pill that field occupied went to the thing
    /// that *is*: what is due, and one tap to it.
    /// On a full-screen iPad the greeting and the pill sit side by side. Stacked,
    /// they leave two thirds of a 1000pt-wide card as empty blue — which is the
    /// difference between a header and a banner nobody asked for. Narrow enough
    /// (portrait, Split View, Slide Over) and it folds back to the stack the
    /// design was drawn as.
    private func greetingCard(_ overview: BackendAPI.LearnOverview, wide: Bool) -> some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: 32) {
                    greetingText
                    Spacer(minLength: 16)
                    headerAction(overview)
                        .frame(maxWidth: 380)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    greetingText
                    Spacer(minLength: 24)
                    headerAction(overview)
                }
            }
        }
        .font(.largeTitle.weight(.bold))
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: wide ? 210 : 230, alignment: .leading)
        .background(headerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var greetingText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hallo,")
                .foregroundStyle(.white.opacity(0.9))
            Text(model.settings.greetingName)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
    }

    /// Two soft discs over a diagonal gradient — the light the flat blue of the
    /// original was drawn with, kept because a 230pt slab of one colour is a
    /// slab, and this is the first thing on the screen.
    private var headerBackground: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Self.headerTop, Self.headerBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 460, height: 460)
                .offset(x: -140, y: -250)
            Circle()
                .fill(.white.opacity(0.05))
                .frame(width: 300, height: 300)
                .offset(x: 90, y: -190)
        }
    }

    /// What the pill says depends on what there is to do: the due cards if any
    /// are due, practice if the deck is learned for today, and nothing at all if
    /// there is no deck — an empty screen should not offer a button that leads
    /// to an empty screen.
    @ViewBuilder
    private func headerAction(_ overview: BackendAPI.LearnOverview) -> some View {
        if overview.dueTotal > 0 {
            headerPill(
                title: "Heute lernen",
                symbol: "sparkles",
                detail: overview.dueTotal == 1 ? "1 Karte" : "\(overview.dueTotal) Karten"
            ) {
                ReviewView(
                    api: api,
                    title: "Heute lernen",
                    mode: .review,
                    loader: loader(subject: nil, dueOnly: true)
                )
            }
        } else if overview.cardTotal > 0 {
            headerPill(
                title: "Karten üben",
                symbol: "checkmark.seal",
                detail: "Alles gelernt"
            ) {
                ReviewView(
                    api: api,
                    title: "Üben",
                    mode: .practice,
                    loader: loader(subject: nil, dueOnly: false)
                )
            }
        }
    }

    private func headerPill<Destination: View>(
        title: String,
        symbol: String,
        detail: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                Text(title)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Self.headerInk.opacity(0.78))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.headerInk.opacity(0.6))
            }
            .font(.headline)
            .foregroundStyle(Self.headerInk)
            .padding(.horizontal, 22)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .background(.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(DeckCardButtonStyle())
    }

    // MARK: - Fächer

    private func subjectsSection(_ overview: BackendAPI.LearnOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Fächer")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)],
                spacing: 18
            ) {
                ForEach(overview.subjects) { subject in
                    SubjectDeckCard(
                        api: api,
                        subject: subject,
                        due: loader(subject: subject.subject, dueOnly: true),
                        practice: loader(subject: subject.subject, dueOnly: false)
                    )
                }
            }
        }
    }

    // MARK: - Noch nicht abgefragt

    /// Lessons whose deck has never been written. A card of rows rather than
    /// more tiles: these are not places to go back to, they are one-off jobs
    /// that disappear the moment they are done.
    private func pendingSection(_ waiting: [BackendAPI.LessonInfo]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Noch nicht abgefragt")
            VStack(spacing: 0) {
                ForEach(Array(waiting.enumerated()), id: \.element.id) { item in
                    if item.offset > 0 {
                        Divider().padding(.leading, 62)
                    }
                    pendingRow(item.element)
                        .disabled(!model.connectivity.isOnline)
                }
            }
            .cardSurface(cornerRadius: 20)
            // The deck for a lesson has to be written before it can be learned,
            // and writing it is the AI's job on the server.
            Text(model.connectivity.isOnline
                ? "Beim ersten Abfragen entsteht der Kartensatz der Stunde."
                : "Neue Kartensätze schreibt die KI auf dem Server — dafür wird eine Verbindung gebraucht.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func pendingRow(_ lesson: BackendAPI.LessonInfo) -> some View {
        let style = subjectStyle(for: lesson.subject)
        return NavigationLink {
            ReviewView(
                api: api,
                title: lesson.title ?? "Stunde abfragen",
                mode: .review
            ) {
                try await api.generateCards(sessionId: lesson.id)
            }
        } label: {
            HStack(spacing: 14) {
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title ?? "Aufnahme")
                        .foregroundStyle(.primary)
                    Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The quiet corners

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Noch nichts zu lernen")
                .font(.headline)
            Text("Nimm eine Stunde auf, dann erscheinen hier ihre Karten.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .padding(.horizontal, 24)
        .cardSurface(cornerRadius: 20)
    }

    /// Answers given offline, waiting for the server. Shown so the count that
    /// does not match the schedule has a visible reason.
    private var queuedNote: some View {
        Label {
            Text(model.reviews.pending.count == 1
                ? "1 Antwort wartet auf den Server"
                : "\(model.reviews.pending.count) Antworten warten auf den Server")
        } icon: {
            Image(systemName: "arrow.up.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.bold))
            .padding(.horizontal, 4)
    }

    // MARK: - Loading

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

/// One subject's deck on the dashboard: the card, the tap, and the menu.
///
/// The menu is a sibling of the navigation link rather than a control inside its
/// label. A `Menu` nested in a link's label does not reliably get its own taps —
/// the link takes them — so the ellipsis is layered over the card and wins the
/// hit test by being on top of it.
///
/// It also carries what a grid has no other room for. As a list row, "Üben" was
/// a swipe action and a long press; a tile can be neither, and practising a deck
/// with nothing due is the reason to open a subject on most evenings.
private struct SubjectDeckCard: View {
    let api: BackendAPI
    let subject: BackendAPI.LearnSubject
    let due: () async throws -> [BackendAPI.LearnCard]
    let practice: () async throws -> [BackendAPI.LearnCard]

    /// Where the menu sends you. The tap on the card itself is a plain
    /// `NavigationLink`; only the menu needs a route it can trigger.
    private enum Route: Hashable {
        case review, practice
    }

    @State private var route: Route?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { subject.subject ?? "Ohne Fach" }

    var body: some View {
        // Read out here rather than inside the transition closure, which is
        // `@Sendable` and would otherwise be capturing the view itself.
        let moves = !reduceMotion
        return ZStack(alignment: .topTrailing) {
            NavigationLink {
                // Tapping the card does the obvious thing: learn what is due,
                // or — when nothing is — practise, rather than opening a screen
                // that says there is nothing here.
                if subject.due > 0 {
                    reviewDestination
                } else {
                    practiceDestination
                }
            } label: {
                SubjectDeckTile(
                    name: name,
                    due: subject.due,
                    total: subject.total,
                    style: subjectStyle(for: subject.subject)
                )
            }
            .buttonStyle(DeckCardButtonStyle())

            DeckCardMenu {
                Button {
                    route = .review
                } label: {
                    Label("Fällige Karten", systemImage: "sparkles")
                }
                .disabled(subject.due == 0)
                Button {
                    route = .practice
                } label: {
                    Label("Alle Karten üben", systemImage: "arrow.clockwise")
                }
                .disabled(subject.total == 0)
            }
            .padding(6)
        }
        .navigationDestination(item: $route) { target in
            switch target {
            case .review: reviewDestination
            case .practice: practiceDestination
            }
        }
        // Cards settle in as they reach the middle of the scroll view rather
        // than arriving already there. Kept small on purpose: a card that is
        // still visibly half-faded at the bottom of the screen reads as a bug
        // rather than as depth.
        .scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.8)
                .scaleEffect(phase.isIdentity || !moves ? 1 : 0.97)
        }
    }

    private var reviewDestination: some View {
        ReviewView(api: api, title: name, mode: .review, loader: due)
    }

    private var practiceDestination: some View {
        ReviewView(api: api, title: "\(name) üben", mode: .practice, loader: practice)
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
