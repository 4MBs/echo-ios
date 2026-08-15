import SwiftUI

struct LearnView: View {
    @Environment(AppModel.self) private var model
    @State private var overview: BackendAPI.LearnOverview?
    @State private var plan: BackendAPI.LearnPlan?
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading, overview == nil {
                    ProgressView("Lernstand wird geladen …")
                } else if let overview, overview.cardTotal == 0 {
                    LearnEmptyView(lessons: lessons, api: api, onGenerated: reload)
                } else if let overview {
                    home(overview)
                } else {
                    ContentUnavailableView(
                        "Lernen nicht verfügbar",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "Die Lerndaten konnten nicht geladen werden.")
                    )
                }
            }
            .navigationTitle("Lernen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aktualisieren", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(isLoading)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func home(_ overview: BackendAPI.LearnOverview) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(overview.dueTotal) heute")
                            .font(.title.bold())
                        Spacer()
                        Text("ca. \(overview.estimatedMinutes) Min.")
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: overview.memoryStrength ?? overview.mastery)
                        .tint(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Erinnerungsstärke \(percent(overview.memoryStrength ?? overview.mastery))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label("\(overview.stateCounts?["learning"] ?? 0) im Lernen", systemImage: "brain")
                        Spacer()
                        if let readiness = overview.readiness {
                            Text("Prüfungsbereit \(percent(readiness))")
                        } else {
                            Text("Noch nicht genug Daten")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let plan, !plan.cards.isEmpty {
                        NavigationLink {
                            LearnReviewView(api: api, cards: plan.cards)
                        } label: {
                            Label("Wiederholung starten", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("learn.start")
                    } else {
                        Text("Für heute ist nichts mehr fällig.")
                            .foregroundStyle(.secondary)
                    }
                    if !cards.isEmpty {
                        NavigationLink {
                            LearnReviewView(api: api, cards: cards, mode: "practice")
                        } label: {
                            Label("Optional weiter üben", systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Fächer und Themen") {
                ForEach(overview.subjects) { subject in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(subject.displayName).font(.headline)
                            Spacer()
                            Text(percent(subject.mastery)).foregroundStyle(.secondary)
                        }
                        ProgressView(value: subject.mastery)
                            .tint(Theme.accent)
                            .accessibilityHidden(true)
                        Text("\(subject.due) fällig · \(subject.total) Konzepte")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink {
                    LearnExamListView(api: api, lessons: lessons)
                } label: {
                    Label("Prüfungen", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    LearnAnalyticsView(api: api)
                } label: {
                    Label("Lernanalyse", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    LearnConceptLibraryView(cards: cards, api: api, onDeleted: reload)
                } label: {
                    Label("Gelernte Konzepte", systemImage: "books.vertical")
                        .badge(cards.count)
                }
                NavigationLink {
                    LearnLessonPickerView(
                        lessons: lessons.filter { !overview.sessionsWithCards.contains($0.id) },
                        api: api,
                        onGenerated: reload
                    )
                } label: {
                    Label("Stunden verarbeiten", systemImage: "sparkles")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        if overview == nil,
           let stored = OfflineCache.load(BackendAPI.LearnOverview.self, key: OfflineCache.Key.learnOverview) {
            overview = stored
        }
        if cards.isEmpty,
           let stored = OfflineCache.load([BackendAPI.LearnCard].self, key: OfflineCache.Key.learnCards) {
            cards = stored
        }
        do {
            async let freshOverview = api.learnOverview()
            async let freshPlan = api.learnPlan()
            async let freshCards = api.learnCards()
            async let freshLessons = api.listLessons()
            let values = try await (freshOverview, freshPlan, freshCards, freshLessons)
            overview = values.0
            plan = values.1
            cards = values.2
            lessons = values.3.filter { $0.segmentCount > 0 }
            OfflineCache.save(values.0, as: OfflineCache.Key.learnOverview)
            OfflineCache.save(values.2, as: OfflineCache.Key.learnCards)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func reload() async {
        await load()
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct LearnEmptyView: View {
    let lessons: [BackendAPI.LessonInfo]
    let api: BackendAPI
    let onGenerated: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Noch keine Lernkonzepte", systemImage: "brain.head.profile")
        } description: {
            Text("Verwandle abgeschlossene Stunden in Fragen, die du aktiv beantwortest.")
        } actions: {
            NavigationLink {
                LearnLessonPickerView(lessons: lessons, api: api, onGenerated: onGenerated)
            } label: {
                Text("Stunden auswählen")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct LearnLessonPickerView: View {
    let lessons: [BackendAPI.LessonInfo]
    let api: BackendAPI
    let onGenerated: () async -> Void
    @State private var generating: String?
    @State private var generated: Set<String> = []
    @State private var errorMessage: String?
    @State private var preview: DraftPreview?

    private struct DraftPreview: Identifiable {
        let lesson: BackendAPI.LessonInfo
        let drafts: [BackendAPI.LearnCardDraft]
        var id: String { lesson.id }
    }

    var body: some View {
        List {
            if lessons.isEmpty {
                ContentUnavailableView(
                    "Keine neuen Stunden",
                    systemImage: "checkmark.circle",
                    description: Text("Alle abgeschlossenen Stunden sind bereits verarbeitet.")
                )
            }
            ForEach(lessons) { lesson in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lesson.displayTitle)
                            .font(.headline)
                        Text(lessonMetadata(lesson))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    if generated.contains(lesson.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if generating == lesson.id {
                        ProgressView()
                    } else {
                        Button("Erstellen") { Task { await generate(lesson) } }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Stunden auswählen")
        .sheet(item: $preview) { value in
            LearnCardDraftPreviewView(
                api: api,
                sessionId: value.lesson.id,
                drafts: value.drafts
            ) {
                generated.insert(value.lesson.id)
                await onGenerated()
            }
        }
    }

    private func lessonMetadata(_ lesson: BackendAPI.LessonInfo) -> String {
        let date = lesson.startedAt.formatted(date: .abbreviated, time: .omitted)
        guard let subject = lesson.displaySubject else { return date }
        return "\(subject) · \(date)"
    }

    private func generate(_ lesson: BackendAPI.LessonInfo) async {
        generating = lesson.id
        errorMessage = nil
        do {
            let drafts = try await api.generateLearnDrafts(sessionId: lesson.id)
            preview = DraftPreview(lesson: lesson, drafts: drafts)
        } catch {
            errorMessage = error.localizedDescription
        }
        generating = nil
    }
}

private struct LearnConceptLibraryView: View {
    @State private var cards: [BackendAPI.LearnCard]
    let api: BackendAPI
    let onDeleted: () async -> Void
    @State private var query = ""
    @State private var pendingDelete: BackendAPI.LearnCard?
    @State private var errorMessage: String?
    @State private var editingCard: BackendAPI.LearnCard?
    @State private var regenerating: Set<String> = []

    init(
        cards: [BackendAPI.LearnCard],
        api: BackendAPI,
        onDeleted: @escaping () async -> Void
    ) {
        _cards = State(initialValue: cards)
        self.api = api
        self.onDeleted = onDeleted
    }

    private var filtered: [BackendAPI.LearnCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cards }
        return cards.filter {
            $0.displayConcept.localizedCaseInsensitiveContains(trimmed)
                || ($0.subject?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        List(filtered) { card in
            conceptLink(card)
                .swipeActions {
                    Button("Konzept löschen", role: .destructive) { pendingDelete = card }
                }
                .contextMenu {
                    Button("Bearbeiten", systemImage: "pencil") { editingCard = card }
                    Button("Neu formulieren", systemImage: "arrow.clockwise") {
                        Task { await regenerate(card) }
                    }
                    Button("Konzept löschen", systemImage: "trash", role: .destructive) {
                        pendingDelete = card
                    }
                }
                .accessibilityIdentifier("learn-concept-\(card.id)")
        }
        .navigationTitle("Gelernte Konzepte")
        .sheet(item: $editingCard) { card in
            LearnCardEditorView(api: api, card: card) { updated in replace(updated) }
        }
        .searchable(text: $query, prompt: "Konzept oder Fach")
        .confirmationDialog(
            "Konzept endgültig löschen?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { card in
            Button("Konzept löschen", role: .destructive) { Task { await delete(card) } }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Das Konzept wird einschließlich aller Stundenquellen und Lernverläufe gelöscht.")
        }
        .alert(
            "Konzept konnte nicht gelöscht werden",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func conceptLink(_ card: BackendAPI.LearnCard) -> some View {
        if let source = card.primarySource {
            NavigationLink {
                LearnSourceView(source: source)
            } label: {
                conceptRow(card)
            }
        } else {
            conceptRow(card)
        }
    }

    private func conceptRow(_ card: BackendAPI.LearnCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.displayConcept).font(.headline)
            Text(card.subject ?? "Sonstige").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func delete(_ card: BackendAPI.LearnCard) async {
        do {
            try await api.deleteLearnCard(id: card.id)
            cards.removeAll { $0.id == card.id }
            OfflineCache.save(cards, as: OfflineCache.Key.learnCards)
            await onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func regenerate(_ card: BackendAPI.LearnCard) async {
        regenerating.insert(card.id)
        do {
            replace(try await api.regenerateLearnCard(
                id: card.id, concept: card.displayConcept, question: card.question
            ))
        } catch { errorMessage = error.localizedDescription }
        regenerating.remove(card.id)
    }

    private func replace(_ updated: BackendAPI.LearnCard) {
        if let index = cards.firstIndex(where: { $0.id == updated.id }) { cards[index] = updated }
        OfflineCache.save(cards, as: OfflineCache.Key.learnCards)
    }
}
