import SwiftUI

/// One exam: when it is, how solid the material is, and the round that closes
/// the gap.
///
/// The page it replaces led with a card in a subject-colour gradient carrying
/// white type — about 1.2:1 for English — and offered three near-identical
/// actions ("Heutige Lernrunde", "Diagnosetest", "Probe-Arbeit") that drew from
/// the same pile. There is one primary action here; the mock paper is a menu
/// item, because writing one is a decision, not a default.
struct ExamView: View {
    @Environment(AppModel.self) private var model

    @State private var exam: BackendAPI.LearnExam
    let store: LearnStore
    let onDeleted: () -> Void

    @State private var confirmingDelete = false
    @State private var editingScope = false
    @State private var updating = false
    @State private var actionError: String?

    init(exam: BackendAPI.LearnExam, store: LearnStore, onDeleted: @escaping () -> Void) {
        _exam = State(initialValue: exam)
        self.store = store
        self.onDeleted = onDeleted
    }

    private var api: BackendAPI { model.api }
    private var deck: [BackendAPI.LearnCard] { store.deck(for: exam) }
    private var lessons: [BackendAPI.LessonInfo] {
        let ids = Set(exam.sessionIds)
        return store.lessons.filter { ids.contains($0.id) }.sortedNewestFirst
    }

    /// Lessons recorded in the exam's period that are not part of it yet. Echo
    /// offers them; it never adds them behind the student's back.
    private var newLessons: [BackendAPI.LessonInfo] {
        let start = LearnDay.date(exam.scopeStart) ?? .distantPast
        let end = LearnDay.date(exam.scopeEnd) ?? .distantFuture
        let known = Set(exam.sessionIds)
        return store.lessons.filter {
            $0.subject == exam.subject && $0.startedAt >= start && $0.startedAt <= end && !known.contains($0.id)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header
                LearnPrimaryButton("Lernrunde starten") { startRound() }
                    .disabled(deck.isEmpty)
                topicSection
                materialSection
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: Theme.Width.column, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.wideScreen)
            .padding(.vertical, Theme.Space.section)
        }
        .groupedScreen()
        .navigationTitle(exam.subject)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .confirmationDialog("Arbeit löschen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await delete() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Lernplan für diese Arbeit wird gelöscht. Deine Karten und dein Lernstand bleiben.")
        }
        .sheet(isPresented: $editingScope) {
            ExamScopeSheet(
                subject: exam.subject,
                lessons: store.lessons.filter { $0.subject == exam.subject },
                selected: Set(exam.sessionIds)
            ) { ids in
                await apply(sessionIds: Array(ids))
            }
        }
        .task { await store.refreshLessons(api: api) }
    }

    // MARK: - Head

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubjectDot(subject: exam.subject)
                Text(exam.subject)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(exam.name.isEmpty ? "Arbeit" : exam.name)
                .font(.title.weight(.bold))
            Text(dateLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ReadinessBar(value: readiness, subject: exam.subject, width: 120)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var dateLine: String {
        let count = deck.count == 1 ? "1 Karte" : "\(deck.count) Karten"
        guard let date = LearnDay.date(exam.examDate) else { return count }
        return "\(LearnDay.short(date)) · \(LearnDay.countdown(days: exam.daysRemaining)) · \(count)"
    }

    private var readiness: Double {
        guard exam.readiness <= 0 else { return exam.readiness }
        guard !deck.isEmpty else { return 0 }
        return deck.map(cardReadiness).reduce(0, +) / Double(deck.count)
    }

    // MARK: - Sections

    @ViewBuilder
    private var topicSection: some View {
        let topics = studyTopics(deck)
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                LearnSectionHeader("Bereitschaft nach Thema")
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

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            LearnSectionHeader("Stoff")
            LearnRowGroup {
                if !newLessons.isEmpty {
                    Button { Task { await includeNewLessons() } } label: {
                        HStack(spacing: Theme.Space.row) {
                            Text(newLessons.count == 1
                                ? "1 neue Stunde aus dem Zeitraum"
                                : "\(newLessons.count) neue Stunden aus dem Zeitraum")
                                .font(.body)
                            Spacer(minLength: 8)
                            Text(updating ? "Wird ergänzt …" : "Hinzufügen")
                                .font(.body)
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, Theme.Space.inset)
                        .padding(.vertical, 14)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(LearnRowButtonStyle())
                    .disabled(updating)
                    LearnRowDivider()
                }
                ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                    ExamLessonRow(lesson: lesson, subject: exam.subject)
                    if index < lessons.count - 1 { LearnRowDivider() }
                }
                if lessons.isEmpty, newLessons.isEmpty {
                    Text("Für diesen Zeitraum sind keine Aufnahmen gespeichert.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.inset)
                        .padding(.vertical, 14)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // Two lines, because a mock paper reschedules cards like a real
                // round does (the server treats `mode: "exam"` that way) and the
                // student should read that before writing one, not after.
                Button {
                    writeMockPaper()
                } label: {
                    Text("Probe schreiben")
                    Text("Zählt für deinen Lernplan")
                }
                .disabled(deck.isEmpty)
                Button("Stoff bearbeiten") { editingScope = true }
                Button("Arbeit löschen", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    /// Today's share of the material, weakest first, cut to the daily goal.
    private func startRound() {
        let budget = max(5, Int(Double(model.settings.dailyLearnMinutes) * 60 / StudyPlan.secondsPerCard))
        let cards = Array(deck.sorted { cardReadiness($0) < cardReadiness($1) }.prefix(budget))
        guard !cards.isEmpty else { return }
        model.startStudy(StudySession(mode: .review, title: exam.name, cards: cards))
    }

    private func writeMockPaper() {
        guard !deck.isEmpty else { return }
        model.startStudy(StudySession(mode: .exam, title: "Probe", cards: deck.shuffled()))
    }

    private func includeNewLessons() async {
        await apply(sessionIds: exam.sessionIds + newLessons.map(\.id), generateFor: newLessons.map(\.id))
    }

    private func apply(sessionIds: [String], generateFor: [String] = []) async {
        updating = true
        defer { updating = false }
        do {
            let updated = try await api.updateLearnExamSessions(id: exam.id, sessionIds: sessionIds)
            exam = updated
            store.replace(updated)
            for id in generateFor {
                _ = try? await api.generateCards(sessionId: id)
            }
            await store.refresh(
                api: api,
                minutes: model.settings.dailyLearnMinutes,
                answered: model.reviews.answeredIDs
            )
            if let refreshed = store.exams.first(where: { $0.id == exam.id }) { exam = refreshed }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete() async {
        guard (try? await api.deleteLearnExam(id: exam.id)) != nil else {
            actionError = "Die Arbeit konnte nicht gelöscht werden."
            return
        }
        // Popping is the caller's job: it owns the navigation value, and
        // dismissing here as well would pop twice.
        store.remove(examID: exam.id)
        onDeleted()
    }
}

/// One lesson of the material: what was taught, and when.
private struct ExamLessonRow: View {
    let lesson: BackendAPI.LessonInfo
    let subject: String

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.topic ?? lesson.summaryExcerpt ?? subject)
                    .font(.body)
                    .lineLimit(1)
                Text(LearnDay.short(lesson.startedAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
