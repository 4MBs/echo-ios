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
                    ProgressView(value: overview.mastery)
                        .tint(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Gesamtbeherrschung \(percent(overview.mastery))")
                        .font(.footnote)
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
                    LearnConceptLibraryView(cards: cards)
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
                        Text(lesson.topic ?? lesson.title ?? lesson.subject ?? "Unterrichtsstunde")
                            .font(.headline)
                        Text(lesson.subject ?? lesson.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
    }

    private func generate(_ lesson: BackendAPI.LessonInfo) async {
        generating = lesson.id
        errorMessage = nil
        do {
            _ = try await api.generateLearnCards(sessionId: lesson.id)
            generated.insert(lesson.id)
            await onGenerated()
        } catch {
            errorMessage = error.localizedDescription
        }
        generating = nil
    }
}

private struct LearnConceptLibraryView: View {
    let cards: [BackendAPI.LearnCard]
    @State private var query = ""

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
        .navigationTitle("Gelernte Konzepte")
        .searchable(text: $query, prompt: "Konzept oder Fach")
    }

    private func conceptRow(_ card: BackendAPI.LearnCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.displayConcept).font(.headline)
            Text(card.subject ?? "Sonstige").font(.caption).foregroundStyle(.secondary)
        }
    }
}
