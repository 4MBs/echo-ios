import SwiftUI

/// "Lernen": one screen that says what is due, and one button that starts it.
///
/// Learning is a *session*, not a dashboard. The area this replaces was three
/// pages behind a segmented picker — Heute, Prüfungen, Fächer — which put a
/// second level of navigation inside a tab, duplicated the Stunden grid with a
/// second kind of tile and a second subject screen, and made the answer to "what
/// should I do now" the fourth thing on the page, under two titles, an
/// explanatory sentence and a time-budget picker.
///
/// So: one screen, one filled button, and everything else a row. What is in
/// today's round, which exams are coming, what is still wobbling. Everything is
/// drawn from the stored deck first and refreshed quietly, because the most
/// common moment this screen is opened in is five minutes on a bus.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    @State private var store = LearnStore()
    @State private var showingNewExam = false
    @State private var openExam: BackendAPI.LearnExam?
    @State private var pendingDelete: BackendAPI.LearnExam?
    @State private var actionError: String?

    private var api: BackendAPI { model.api }
    private var answered: Set<String> { model.reviews.answeredIDs }
    private var minutes: Int { model.settings.dailyLearnMinutes }
    private var plan: StudyPlan { store.plan(minutes: minutes, answered: answered) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    content(width: geo.size.width)
                        .padding(.horizontal, geo.size.width >= Theme.Width.column
                            ? Theme.Space.wideScreen
                            : Theme.Space.screen)
                        .padding(.top, 8)
                        .padding(.bottom, 36)
                }
                .refreshable { await load() }
            }
            .groupedScreen()
            .navigationTitle("Lernen")
            .toolbar { toolbarMenu }
            .navigationDestination(item: $openExam) { exam in
                ExamView(exam: exam, store: store) { openExam = nil }
            }
        }
        .sheet(isPresented: $showingNewExam) {
            NewExamView(api: api, store: store, defaultMinutes: minutes) { exam in
                store.replace(exam)
                await load()
            }
        }
        .confirmationDialog(
            "Arbeit löschen?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { exam in
            Button("Löschen", role: .destructive) { Task { await delete(exam) } }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Der Lernplan für diese Arbeit wird gelöscht. Deine Karten und dein Lernstand bleiben.")
        }
        .alert(
            "Arbeit konnte nicht gelöscht werden",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
        // A round that just rescheduled twelve cards leaves this screen saying
        // twelve are due. Reloading when the modal closes is what makes the
        // count on the way out agree with the work that was just done —
        // offline as well, where the queue is what the plan is filtered by.
        .onChange(of: model.studySession == nil) { _, ended in
            if ended { Task { await load() } }
        }
    }

    // MARK: - The screen

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let failure = store.failure, !store.hasContent {
            ErrorState(failure) { await load() }
                .padding(.top, 40)
        } else if !store.hasContent, !store.hasReadCache || store.isLoading {
            LearnSkeleton()
                .padding(.top, 12)
        } else if store.cards.isEmpty, plan.isEmpty, store.exams.isEmpty {
            noCardsYet
        } else if width >= Theme.Width.twoColumn {
            // Two columns, each held to a readable measure and the pair centred:
            // stretching a row of six words across 1300pt is what makes an iPad
            // app look like a resized phone app.
            HStack(alignment: .top, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    startSection
                    planSection
                }
                .frame(maxWidth: Theme.Width.column)
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    examSection
                    weakSection
                    footer
                }
                .frame(maxWidth: Theme.Width.column)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // One column that fills the panel rather than a 700pt strip with
            // dead grey beside it: these are rows of four or five words, not
            // paragraphs, so they stay readable at any width this branch sees.
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                startSection
                planSection
                examSection
                weakSection
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The answer to "what now", and the button that does it.
    private var startSection: some View {
        TodayHero(
            plan: plan,
            resumable: model.resumableSession,
            hasCards: !store.cards.isEmpty,
            nextDue: store.nextDueDate(answered: answered),
            onResume: { model.resumeStudy() },
            onStart: {
                model.startStudy(StudySession(mode: .review, title: "Lernrunde", cards: plan.cards))
            },
            onPractise: {
                let deck = Array(store.cards.sorted { cardReadiness($0) < cardReadiness($1) }.prefix(20))
                model.startStudy(StudySession(mode: .practice, title: "Üben", cards: deck))
            }
        )
    }

    /// What is in the round, and — beside the heading — the one setting that
    /// shapes it.
    @ViewBuilder
    private var planSection: some View {
        if !plan.blocks.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                HStack(alignment: .firstTextBaseline) {
                    LearnSectionHeader("Was drin ist")
                    Spacer(minLength: 8)
                    DailyGoalMenu(minutes: minutesBinding)
                }
                LearnRowGroup {
                    ForEach(Array(plan.blocks.enumerated()), id: \.element.id) { index, block in
                        PlanBlockRow(block: block)
                        if index < plan.blocks.count - 1 { LearnRowDivider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var examSection: some View {
        if !store.exams.isEmpty || !store.examsUnavailable {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                LearnSectionHeader("Arbeiten")
                LearnRowGroup {
                    if store.upcomingExams.isEmpty {
                        Button { showingNewExam = true } label: {
                            LearnActionRow(title: "Arbeit eintragen", systemImage: "plus")
                        }
                        .buttonStyle(LearnRowButtonStyle())
                    } else {
                        ForEach(Array(store.upcomingExams.enumerated()), id: \.element.id) { index, exam in
                            Button { openExam = exam } label: {
                                ExamRow(exam: exam, readiness: readiness(for: exam))
                            }
                            .buttonStyle(LearnRowButtonStyle())
                            .contextMenu {
                                Button("Arbeit löschen", role: .destructive) { pendingDelete = exam }
                            }
                            if index < store.upcomingExams.count - 1 { LearnRowDivider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var weakSection: some View {
        let topics = weakTopics
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                LearnSectionHeader("Wackelt noch")
                LearnRowGroup {
                    ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                        Button {
                            model.startStudy(
                                StudySession(mode: .practice, title: topic.name, cards: topic.cards)
                            )
                        } label: {
                            TopicRow(topic: topic)
                        }
                        .buttonStyle(LearnRowButtonStyle())
                        if index < topics.count - 1 { LearnRowDivider() }
                    }
                }
            }
        }
    }

    private var footer: some View {
        LearnStatusFooter(
            isOnline: model.connectivity.isOnline,
            storedAt: store.storedAt,
            pendingAnswers: model.reviews.pending.count,
            examsUnavailable: store.examsUnavailable
        )
    }

    /// No deck anywhere: the one state that is a beginning rather than a lack.
    private var noCardsYet: some View {
        ContentUnavailableView {
            Label("Hier entstehen deine Karten", systemImage: "sparkles")
        } description: {
            Text("Nimm eine Stunde auf. Aus dem Transkript schreibt die KI danach die Fragen.")
        } actions: {
            Button("Zur Aufnahme") { model.selectedTab = .aufnahme }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Menu("Fach üben …") {
                    ForEach(store.subjectsWithCards, id: \.self) { subject in
                        Button(subjectMenuTitle(subject)) { practise(subject) }
                    }
                }
                .disabled(store.subjectsWithCards.isEmpty)
                // Only when the section is not already showing the row for it:
                // entering an exam is one action, and it is reachable once.
                if !store.upcomingExams.isEmpty {
                    Button("Arbeit eintragen") { showingNewExam = true }
                }
                NavigationLink("Lernen-Einstellungen") { LearnSettingsView() }
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
        }
    }

    private func subjectMenuTitle(_ subject: String) -> String {
        let due = dueCards(in: subject).count
        return due > 0 ? "\(subject) · \(due) fällig" : subject
    }

    // MARK: - What the screen says

    /// At most three, and only the ones that actually wobble.
    ///
    /// Not the new ones: a topic nobody has answered yet is not shaky, it is
    /// unseen, and today's round is already about to ask it. A list of
    /// everything here would be a second deck rather than a hint.
    private var weakTopics: [StudyTopic] {
        let wobbling = studyTopics(store.cards)
            .filter { $0.cards.count >= 2 && Readiness($0.readiness) == .shaky }
        return Array(wobbling.prefix(3))
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { model.settings.dailyLearnMinutes },
            set: { value in
                guard value != model.settings.dailyLearnMinutes else { return }
                model.settings.dailyLearnMinutes = value
                Task { await load() }
            }
        )
    }

    private func readiness(for exam: BackendAPI.LearnExam) -> Double {
        // The server's own number where it has one; the local approximation only
        // for an exam it has not scored yet.
        guard exam.readiness <= 0 else { return exam.readiness }
        let deck = store.deck(for: exam)
        guard !deck.isEmpty else { return 0 }
        return deck.map(cardReadiness).reduce(0, +) / Double(deck.count)
    }

    private func dueCards(in subject: String) -> [BackendAPI.LearnCard] {
        let scope: SubjectScope = subject == otherSubjectName ? .unfiled : .named(subject)
        let today = LearnDay.today
        return store.cards.filter { scope.contains($0) && isCardDue($0, today: today, answered: answered) }
    }

    private func practise(_ subject: String) {
        let scope: SubjectScope = subject == otherSubjectName ? .unfiled : .named(subject)
        let due = dueCards(in: subject)
        if !due.isEmpty {
            model.startStudy(StudySession(mode: .review, title: subject, cards: StudyPlan.interleaved(due)))
            return
        }
        let deck = store.cards.filter { scope.contains($0) }
        guard !deck.isEmpty else { return }
        model.startStudy(
            StudySession(
                mode: .practice,
                title: subject,
                cards: Array(deck.sorted { cardReadiness($0) < cardReadiness($1) }.prefix(20))
            )
        )
    }

    // MARK: - Loading

    private func load() async {
        store.primeFromCache()
        await store.refresh(api: api, minutes: minutes, answered: answered)
        await model.flushQueuedReviews()
    }

    /// The row stays where it is when the server refuses — a deletion that
    /// silently did not happen is worse than one that says so.
    private func delete(_ exam: BackendAPI.LearnExam) async {
        do {
            try await api.deleteLearnExam(id: exam.id)
        } catch {
            actionError = error.localizedDescription
            return
        }
        store.remove(examID: exam.id)
        await load()
    }
}
