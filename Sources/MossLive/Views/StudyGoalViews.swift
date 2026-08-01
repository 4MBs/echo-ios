import SwiftUI

struct NewExamView: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    let subjectNames: [String]
    let suggestions: [BackendAPI.Lesson]
    let onSave: @MainActor (BackendAPI.NewLearnExam) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = "Klassenarbeit"
    @State private var subject: String
    @State private var examDate: Date
    @State private var scopeStart: Date
    @State private var dailyMinutes = 30
    @State private var target = ""
    @State private var selectedSessions = Set<String>()
    @State private var selectedSuggestion = ""
    @State private var saving = false

    init(
        api: BackendAPI,
        lessons: [BackendAPI.LessonInfo],
        subjectNames: [String],
        suggestions: [BackendAPI.Lesson],
        onSave: @escaping @MainActor (BackendAPI.NewLearnExam) async -> Void
    ) {
        self.api = api
        self.lessons = lessons
        self.subjectNames = subjectNames
        self.suggestions = suggestions
        self.onSave = onSave
        let initialDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
        let initialStart = Calendar.current.date(byAdding: .day, value: -42, to: initialDate) ?? Date()
        _subject = State(initialValue: subjectNames.first ?? "Sonstige")
        _examDate = State(initialValue: initialDate)
        _scopeStart = State(initialValue: initialStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !suggestions.isEmpty {
                    Section("Aus WebUntis übernehmen") {
                        Picker("Erkannte Prüfung", selection: $selectedSuggestion) {
                            Text("Manuell anlegen").tag("")
                            ForEach(suggestions) { suggestion in
                                Text("\(suggestion.title) · \(suggestion.date)").tag(suggestion.id)
                            }
                        }
                        .onChange(of: selectedSuggestion) { _, value in
                            applySuggestion(value)
                        }
                    }
                }

                Section("Prüfung") {
                    TextField("Name", text: $name)
                    Picker("Fach", selection: $subject) {
                        ForEach(subjectNames, id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker(
                        "Termin",
                        selection: $examDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    TextField("Ziel, z. B. Note 2", text: $target)
                }

                Section {
                    DatePicker("Stoff ab", selection: $scopeStart, in: ...examDate, displayedComponents: .date)
                    Picker("Zeit pro Tag", selection: $dailyMinutes) {
                        ForEach([10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) Minuten").tag($0) }
                    }
                    Button("Alle Stunden im Zeitraum auswählen") { selectMatchingLessons() }
                } header: {
                    Text("Lernplan")
                } footer: {
                    Text(
                        "Neue Stunden in diesem Zeitraum werden später als Ergänzung vorgeschlagen, aber nicht unbemerkt hinzugefügt."
                    )
                }

                Section("Enthaltene Unterrichtsstunden") {
                    if matchingLessons.isEmpty {
                        Text("In diesem Zeitraum wurden keine passenden Aufnahmen gefunden.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matchingLessons) { lesson in
                            Button {
                                if selectedSessions.contains(lesson.id) {
                                    selectedSessions.remove(lesson.id)
                                } else {
                                    selectedSessions.insert(lesson.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(lesson.topic ?? lesson.title ?? subject)
                                            .foregroundStyle(.primary)
                                        Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedSessions
                                        .contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedSessions.contains(lesson.id) ? Theme
                                            .accent : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Für eine Arbeit lernen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Erstelle …" : "Lernplan erstellen") {
                        save()
                    }
                    .disabled(saving || subject.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { selectMatchingLessons() }
            .onChange(of: subject) { _, _ in selectMatchingLessons() }
            .onChange(of: scopeStart) { _, _ in selectMatchingLessons() }
            .onChange(of: examDate) { _, _ in selectMatchingLessons() }
        }
    }

    private var matchingLessons: [BackendAPI.LessonInfo] {
        lessons.filter { lesson in
            lesson.subject == subject && lesson.startedAt >= scopeStart && lesson.startedAt <= examDate
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func selectMatchingLessons() {
        selectedSessions = Set(matchingLessons.map(\.id))
    }

    private func applySuggestion(_ id: String) {
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        subject = suggestion.subjectLong ?? suggestion.subject
        name = "\(suggestion.title)-Arbeit"
        if let date = suggestion.startDate { examDate = date }
        scopeStart = Calendar.current.date(byAdding: .day, value: -42, to: examDate) ?? scopeStart
        selectMatchingLessons()
    }

    private func save() {
        saving = true
        let exam = BackendAPI.NewLearnExam(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: subject,
            examDate: StudyGoalDate.iso(examDate),
            scopeStart: StudyGoalDate.iso(scopeStart),
            scopeEnd: StudyGoalDate.iso(examDate),
            dailyMinutes: dailyMinutes,
            target: target.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sessionIds: Array(selectedSessions)
        )
        Task {
            await onSave(exam)
            saving = false
            dismiss()
        }
    }
}

struct StudySubjectView: View {
    let api: BackendAPI
    let folder: LearnFolder
    let cards: [BackendAPI.LearnCard]

    @State private var exams: [BackendAPI.LearnExam] = []
    @State private var showingExam = false

    private var subjectCards: [BackendAPI.LearnCard] {
        cards.filter { folder.subject == nil ? $0.subject == nil : $0.subject == folder.subject }
    }

    private var concepts: [StudyTopic] { studyTopics(subjectCards) }

    private var readiness: Double {
        guard !subjectCards.isEmpty else { return 0 }
        return subjectCards.map(studyCardReadiness).reduce(0, +) / Double(subjectCards.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                subjectHero
                actions

                if let exam = exams.first(where: { $0.subject == folder.name && $0.daysRemaining >= 0 }) {
                    NavigationLink {
                        ExamStudyView(api: api, exam: exam, lessons: folder.lessons, cards: subjectCards)
                    } label: {
                        HStack {
                            Label(exam.name, systemImage: "calendar")
                            Spacer()
                            Text("Noch \(exam.daysRemaining) Tage")
                            Image(systemName: "chevron.right")
                        }
                        .font(.headline)
                        .padding(16)
                        .cardSurface()
                    }
                    .buttonStyle(.plain)
                }

                if !concepts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Themen und Wissenslücken").font(.title2.bold())
                        ForEach(concepts) { topic in
                            NavigationLink {
                                ReviewView(api: api, title: topic.name, mode: .practice) { topic.cards }
                            } label: {
                                TopicRow(topic: topic)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                NavigationLink {
                    LearnSubjectView(
                        api: api,
                        name: folder.name,
                        scope: folder.scope,
                        lessons: folder.lessons,
                        decks: lessonDecks(from: subjectCards, answered: [])
                    )
                } label: {
                    Label("Alle Unterrichtsstunden", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .cardSurface()
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .groupedScreen()
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { exams = await (try? api.learnExams()) ?? [] }
        .sheet(isPresented: $showingExam) {
            NewExamView(api: api, lessons: folder.lessons, subjectNames: [folder.name], suggestions: []) { exam in
                _ = try? await api.createLearnExam(exam)
                exams = await (try? api.learnExams()) ?? exams
            }
        }
    }

    private var subjectHero: some View {
        let style = subjectStyle(for: folder.name)
        return HStack(spacing: 18) {
            Image(style.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
                .padding(16)
                .background(.black.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name).font(.largeTitle.bold())
                Text(readiness == 0 ? "Noch nicht genügend geprüft" : "\(Int(readiness * 100)) % Lernbereitschaft")
                    .foregroundStyle(.white.opacity(0.88))
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(style.tint.color, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            NavigationLink {
                ReviewView(api: api, title: "\(folder.name) – 5 Minuten", mode: .review) {
                    Array(subjectCards.sorted { studyCardReadiness($0) < studyCardReadiness($1) }.prefix(7))
                }
            } label: {
                Label("5 Min. starten", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(subjectCards.isEmpty)

            Button {
                showingExam = true
            } label: {
                Label("Arbeit", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

struct ExamStudyView: View {
    let api: BackendAPI
    @State private var exam: BackendAPI.LearnExam
    let lessons: [BackendAPI.LessonInfo]
    @State private var cards: [BackendAPI.LearnCard]
    @State private var updating = false

    init(api: BackendAPI, exam: BackendAPI.LearnExam, lessons: [BackendAPI.LessonInfo], cards: [BackendAPI.LearnCard]) {
        self.api = api
        _exam = State(initialValue: exam)
        self.lessons = lessons
        _cards = State(initialValue: cards)
    }

    private var examCards: [BackendAPI.LearnCard] {
        cards.filter { exam.sessionIds.contains($0.sessionId) }
    }

    private var newMatchingLessons: [BackendAPI.LessonInfo] {
        let start = exam.scopeStart.flatMap(StudyGoalDate.date) ?? .distantPast
        let end = exam.scopeEnd.flatMap(StudyGoalDate.date) ?? .distantFuture
        return lessons.filter {
            $0.subject == exam.subject && $0.startedAt >= start && $0.startedAt <= end && !exam.sessionIds
                .contains($0.id)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ExamLargeCard(exam: exam)

                if !newMatchingLessons.isEmpty {
                    Button {
                        Task { await includeNewLessons() }
                    } label: {
                        Label(
                            updating ? "Aktualisiere …" :
                                "\(newMatchingLessons.count) neue Stunden zum Stoff hinzufügen",
                            systemImage: "sparkles"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updating)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Jetzt lernen").font(.title2.bold())
                    NavigationLink {
                        ReviewView(api: api, title: "\(exam.name) – Lernrunde", mode: .review) {
                            dailyExamCards
                        }
                    } label: {
                        StudyActionCard(
                            title: "Heutige Lernrunde",
                            detail: "Schwächen zuerst · etwa \(exam.dailyMinutes) Minuten",
                            icon: "target",
                            color: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(examCards.isEmpty)

                    NavigationLink {
                        ReviewView(api: api, title: "Diagnosetest", mode: .exam) {
                            Array(examCards.sorted { studyCardReadiness($0) < studyCardReadiness($1) }.prefix(12))
                        }
                    } label: {
                        StudyActionCard(
                            title: "Diagnosetest",
                            detail: "Finde die größten Wissenslücken",
                            icon: "waveform.path.ecg",
                            color: .orange
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(examCards.isEmpty)

                    NavigationLink {
                        ReviewView(api: api, title: "Probe-Arbeit", mode: .exam) { examCards.shuffled() }
                    } label: {
                        StudyActionCard(
                            title: "Probe-Arbeit",
                            detail: "Gemischte Fragen aus dem gesamten Zeitraum",
                            icon: "doc.text.magnifyingglass",
                            color: .purple
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(examCards.isEmpty)
                }

                let topics = studyTopics(examCards)
                if !topics.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bereitschaft nach Thema").font(.title2.bold())
                        ForEach(topics) { TopicRow(topic: $0) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Enthaltener Unterricht").font(.title2.bold())
                    ForEach(lessons.filter { exam.sessionIds.contains($0.id) }) { lesson in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(lesson.topic ?? lesson.title ?? exam.subject).font(.headline)
                                Text(lesson.startedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .padding(14)
                        .cardSurface(cornerRadius: 14)
                    }
                }
            }
            .padding(20)
        }
        .groupedScreen()
        .navigationTitle(exam.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dailyExamCards: [BackendAPI.LearnCard] {
        let count = max(5, min(examCards.count, exam.dailyMinutes * 60 / 45))
        return Array(examCards.sorted { studyCardReadiness($0) < studyCardReadiness($1) }.prefix(count))
    }

    private func includeNewLessons() async {
        updating = true
        defer { updating = false }
        let ids = exam.sessionIds + newMatchingLessons.map(\.id)
        guard let updated = try? await api.updateLearnExamSessions(id: exam.id, sessionIds: ids) else { return }
        exam = updated
        for lesson in newMatchingLessons {
            _ = try? await api.generateCards(sessionId: lesson.id)
        }
        cards = await (try? api.allCards()) ?? cards
        if let refreshedExams = try? await api.learnExams(),
           let refreshed = refreshedExams.first(where: { $0.id == exam.id }) {
            exam = refreshed
        }
    }
}

private struct StudyActionCard: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(15)
        .cardSurface(cornerRadius: 15)
    }
}

private struct StudyTopic: Identifiable {
    let name: String
    let cards: [BackendAPI.LearnCard]
    let readiness: Double
    var id: String { name }
}

private struct TopicRow: View {
    let topic: StudyTopic

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.name).font(.headline)
                Text("\(topic.cards.count) Fragen").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(topic.readiness == 0 ? "Ungeprüft" : "\(Int(topic.readiness * 100)) %")
                .font(.caption.bold())
                .foregroundStyle(topic.readiness >= 0.75 ? .green : topic.readiness >= 0.45 ? .orange : .red)
        }
        .padding(14)
        .cardSurface(cornerRadius: 14)
    }
}

private func studyTopics(_ cards: [BackendAPI.LearnCard]) -> [StudyTopic] {
    Dictionary(grouping: cards) {
        $0.concept?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? $0.lessonTitle?.nilIfEmpty
            ?? "Allgemein"
    }
    .map { name, cards in
        let readiness = cards.map(studyCardReadiness).reduce(0, +) / Double(max(1, cards.count))
        return StudyTopic(name: name, cards: cards, readiness: readiness)
    }
    .sorted { $0.readiness < $1.readiness }
}

private func studyCardReadiness(_ card: BackendAPI.LearnCard) -> Double {
    guard (card.reps ?? 0) > 0 else { return 0 }
    let stability = max(0, card.stability ?? Double(card.box))
    return max(0, min(1, log2(stability + 2) / 6 - min(0.25, Double(card.lapses ?? 0) * 0.03)))
}

private enum StudyGoalDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func iso(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ value: String) -> Date? { formatter.date(from: value) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
