import SwiftUI
import UserNotifications

/// "Lernen": the spaced-repetition home, as a dashboard.
///
/// It opens with who it is talking to and the one thing worth doing right now,
/// then a grid of every subject of the school year. The schedule lives on the
/// server (Leitner ladder), but the deck itself is kept here — cards never
/// change once written, so learning is the one thing in the app that has no
/// business needing a network.
///
/// This was a list of rows: "Heute lernen", then a subject per line, then the
/// lessons with no deck yet. Everything was the same height and the same
/// weight, so the screen had no answer to the question it exists to answer —
/// *what should I do now*. The header answers it, and the grid is the map.
///
/// The grid is the whole body. A subject opens its lessons and a lesson opens
/// its cards, so the recordings with no deck yet are found where they belong —
/// inside the subject they were taught in — rather than in a second list
/// underneath that had every subject mixed together.
struct LearnView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: BackendAPI.LearnOverview?
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var cards: [BackendAPI.LearnCard] = []
    /// Every subject of the school year, from the timetable. The grid is built
    /// from this rather than from the deck, so a subject you have not recorded
    /// yet still has its card.
    @State private var catalogue: [BackendAPI.SubjectInfo] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var loadError: Error?
    /// The subject whose card was tapped while it had nothing in it.
    @State private var emptySubject: String?

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

    /// Where a deck card's menu sends you.
    ///
    /// Held here rather than in the card, because `navigationDestination` has to
    /// be declared on a view that stays alive. A card in a `LazyVGrid` does not:
    /// scroll it off and its destination goes with it. One declaration on the
    /// screen itself, and the cards only have to say where they want to go.
    @State private var deckRoute: DeckRoute?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Lernen")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $deckRoute) { route in
                    deckDestination(route)
                }
                .emptySubjectNotice($emptySubject) { subject in
                    "In \(subject) ist noch nichts aufgenommen. "
                        + "Nimm eine Stunde in diesem Fach auf, dann entstehen hier Karten."
                }
        }
    }

    private func deckDestination(_ route: DeckRoute) -> some View {
        ReviewView(
            api: api,
            title: route.practice ? "\(route.name) üben" : route.name,
            mode: route.practice ? ReviewView.Mode.practice : ReviewView.Mode.review,
            loader: loader(route.scope, dueOnly: !route.practice)
        )
    }

    /// The grid: every subject of the school year, plus any subject only the
    /// archive still remembers, plus Sonstige.
    ///
    /// Nothing is filtered out for being empty. A timetable subject with no
    /// recordings is a real subject you have not recorded yet, and hiding it
    /// would make the grid rearrange itself every time a lesson was taped.
    private var folders: [LearnFolder] {
        var filed: [String: [BackendAPI.LessonInfo]] = [:]
        var unfiled: [BackendAPI.LessonInfo] = []
        for lesson in lessons {
            let subject = (lesson.subject ?? "").trimmingCharacters(in: .whitespaces)
            if subject.isEmpty {
                unfiled.append(lesson)
            } else {
                filed[subject, default: []].append(lesson)
            }
        }

        // The server's per-subject counts, keyed the way the archive labels a
        // recording. The empty key is the catch-all's.
        var counts: [String: BackendAPI.LearnSubject] = [:]
        for entry in shownOverview?.subjects ?? [] {
            counts[entry.subject ?? ""] = entry
        }

        var names = Set(filed.keys)
        names.formUnion(catalogue.map(\.name))
        var out = names.map { name in
            LearnFolder(
                name: name,
                subject: name,
                lessons: (filed[name] ?? []).sortedNewestFirst,
                due: counts[name]?.due ?? 0,
                cardCount: counts[name]?.total ?? 0
            )
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Sonstige is not a subject, so it is appended after the sort rather
        // than competing alphabetically with the ones that are.
        out.append(
            LearnFolder(
                name: otherSubjectName,
                subject: nil,
                lessons: unfiled.sortedNewestFirst,
                due: counts[""]?.due ?? 0,
                cardCount: counts[""]?.total ?? 0
            )
        )
        return out
    }

    /// Every lesson's cards, keyed by session. Built once for the whole screen:
    /// working it out per subject would walk the entire deck once per card in
    /// the grid.
    private var decksBySession: [String: LessonDeck] {
        lessonDecks(from: cards, answered: model.reviews.answeredIDs)
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

    private func isDue(_ card: BackendAPI.LearnCard) -> Bool {
        isCardDue(card, today: LearnDay.today, answered: model.reviews.answeredIDs)
    }

    private func matches(_ card: BackendAPI.LearnCard, _ scope: SubjectScope) -> Bool {
        switch scope {
        case .everything: true
        case .named(let name): card.subject == name
        case .unfiled: card.subject == nil
        }
    }

    private func storedCards(_ scope: SubjectScope, dueOnly: Bool) -> [BackendAPI.LearnCard] {
        // Practice never touches the schedule, so it may ask anything.
        cards.filter { matches($0, scope) && (dueOnly ? isDue($0) : true) }
    }

    /// Ask the server, and fall back to the stored deck when it cannot be
    /// reached. Written this way round so a flaky connection degrades instead
    /// of failing, and so the fallback is never used when the server is fine.
    ///
    /// The fallback is taken here rather than inside the closure: this runs
    /// while the view is on screen, and reading the environment from an
    /// escaping closure that outlives the body is not allowed.
    private func loader(_ scope: SubjectScope, dueOnly: Bool) -> () async throws -> [BackendAPI.LearnCard] {
        let client = api
        let stored = storedCards(scope, dueOnly: dueOnly)
        // Sonstige never goes to the server: there is no query for "cards whose
        // subject is absent", and asking with an empty one would return the
        // whole deck instead.
        if scope.isUnfiled { return { stored } }
        let query = scope.query
        return {
            do {
                return dueOnly
                    ? try await client.dueCards(subject: query)
                    : try await client.allCards(subject: query)
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
        let grid = folders
        let decks = decksBySession
        let nothingAtAll = lessons.isEmpty && catalogue.isEmpty
        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greetingCard(overview, wide: geo.size.width >= Self.wideHeaderWidth)
                    if nothingAtAll {
                        emptyCard
                    } else {
                        subjectsSection(grid, decks: decks)
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
    ///
    /// On a full-screen iPad the greeting and the pill sit side by side. Stacked,
    /// they leave two thirds of a 1000pt-wide card as empty blue — which is the
    /// difference between a header and a banner nobody asked for. Narrow the
    /// window enough and it folds back to the stack the design was drawn as.
    /// Measured, not asked of the size class: iPadOS 26 windows resize freely,
    /// so there is no longer a discrete "compact" state to branch on.
    private func greetingCard(_ overview: BackendAPI.LearnOverview, wide: Bool) -> some View {
        // Spelled out rather than written inline in the frame: `minHeight` takes
        // an optional, and a bare-literal ternary flowing into one is the kind
        // of inference this codebase has been bitten by before.
        let height: CGFloat = wide ? 210 : 230
        return Group {
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
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        // The closure form, not `.background(someView)` — that overload has been
        // deprecated since iOS 15.
        .background { headerBackground }
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
                    loader: loader(.everything, dueOnly: true)
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
                    loader: loader(.everything, dueOnly: false)
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
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - Fächer

    private func subjectsSection(_ grid: [LearnFolder], decks: [String: LessonDeck]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Fächer")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)],
                spacing: 18
            ) {
                ForEach(grid) { folder in
                    SubjectDeckCard(
                        api: api,
                        folder: folder,
                        decks: decks,
                        route: $deckRoute,
                        onBlocked: { emptySubject = folder.name }
                    )
                }
            }
        }
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
        let subjectsKey = OfflineCache.Key.timetableSubjects

        // First time in: everything stored, so the screen is usable before —
        // and without — a reply.
        if overview == nil, cards.isEmpty {
            overview = OfflineCache.load(BackendAPI.LearnOverview.self, key: overviewKey)
            cards = OfflineCache.load([BackendAPI.LearnCard].self, key: cardsKey) ?? []
            lessons = OfflineCache.load([BackendAPI.LessonInfo].self, key: lessonsKey) ?? []
        }
        if catalogue.isEmpty {
            catalogue = OfflineCache.load([BackendAPI.SubjectInfo].self, key: subjectsKey) ?? []
        }
        if shownOverview == nil { loading = true }
        loadError = nil

        // The catalogue is the nicety, not the archive: a server with no
        // timetable connected — or one too old to know the endpoint — leaves the
        // grid to the subjects that were actually recorded. It is awaited on
        // every path below, or the fetch is cancelled on the way out.
        async let remoteSubjects = api.timetableSubjects()

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
        if let fresh = try? await remoteSubjects, !fresh.isEmpty {
            catalogue = fresh
            OfflineCache.save(fresh, as: subjectsKey)
        }
        loading = false
    }
}

/// A deck, and how it is being opened. The whole route, so the screen can
/// rebuild the destination from it without holding a closure per card.
private struct DeckRoute: Hashable {
    let scope: SubjectScope
    /// What to call it on the screen it opens.
    let name: String
    /// Practice asks the whole deck and never touches the schedule; review asks
    /// only what is due and does.
    let practice: Bool
}

/// One subject on the dashboard: the card, where it goes, and the menu.
///
/// A subject with recordings opens its list of lessons. A subject with none is
/// still drawn — it is a subject of the school year whether or not it has been
/// recorded — but it opens nothing, because the screen behind it would be blank.
/// Tapping it says so instead.
///
/// The menu is a sibling of the navigation link rather than a control inside its
/// label. A `Menu` nested in a link's label does not reliably get its own taps —
/// the link takes them — so the ellipsis is layered over the card and wins the
/// hit test by being on top of it. It carries the two shortcuts past the lesson
/// list: everything due in the subject, and the whole deck as practice.
private struct SubjectDeckCard: View {
    let api: BackendAPI
    let folder: LearnFolder
    let decks: [String: LessonDeck]
    /// The screen's one navigation destination, for the menu's two shortcuts.
    /// The tap on the card itself is a plain `NavigationLink` and needs nothing.
    @Binding var route: DeckRoute?
    /// Called when a card with nothing in it is tapped.
    let onBlocked: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read out here rather than inside the transition closure, which is
        // `@Sendable` and would otherwise be capturing the view itself.
        let moves = !reduceMotion
        return ZStack(alignment: .topTrailing) {
            opener
            if !folder.isEmpty {
                menu
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

    /// A link when there is somewhere to go, a button when there is not.
    ///
    /// Not `.disabled()` on the link: a disabled control is dimmed by the system
    /// and then silent, and silence is the one thing a tap on an empty subject
    /// must not be — the card looks exactly like the fifteen next to it.
    @ViewBuilder
    private var opener: some View {
        if folder.isEmpty {
            Button(action: onBlocked) { tile }
                .buttonStyle(PressableCardStyle())
                .accessibilityHint("Noch keine Aufnahmen")
        } else {
            NavigationLink {
                LearnSubjectView(
                    api: api,
                    name: folder.name,
                    scope: folder.scope,
                    lessons: folder.lessons,
                    decks: decks
                )
            } label: {
                tile
            }
            .buttonStyle(PressableCardStyle())
        }
    }

    private var tile: some View {
        SubjectDeckTile(
            name: folder.name,
            due: folder.due,
            cardCount: folder.cardCount,
            lessonCount: folder.lessons.count,
            style: subjectStyle(for: folder.name)
        )
    }

    private var menu: some View {
        DeckCardMenu {
            Button {
                route = DeckRoute(scope: folder.scope, name: folder.name, practice: false)
            } label: {
                Label("Alle fälligen Karten", systemImage: "sparkles")
            }
            .disabled(folder.due == 0)
            Button {
                route = DeckRoute(scope: folder.scope, name: folder.name, practice: true)
            } label: {
                Label("Alle Karten üben", systemImage: "arrow.clockwise")
            }
            .disabled(folder.cardCount == 0)
        }
        .padding(6)
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
