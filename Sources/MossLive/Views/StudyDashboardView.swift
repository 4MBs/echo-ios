import SwiftUI

/// Goal-first learning home. Subjects remain the library, while the first two
/// areas answer the questions students actually arrive with: what to learn
/// today, and how to be ready for a dated exam.
struct StudyDashboardView: View {
    private enum Area: String, CaseIterable, Identifiable {
        case today = "Heute"
        case exams = "Prüfungen"
        case subjects = "Fächer"

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model

    @State private var selectedArea = Area.today
    @State private var dailyMinutes = 30
    @State private var overview: BackendAPI.LearnOverview?
    @State private var plan: BackendAPI.LearnDailyPlan?
    @State private var exams: [BackendAPI.LearnExam] = []
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var cards: [BackendAPI.LearnCard] = []
    @State private var subjects: [BackendAPI.SubjectInfo] = []
    @State private var examSuggestions: [BackendAPI.Lesson] = []
    @State private var loading = true
    @State private var error: Error?
    @State private var showingNewExam = false

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            Group {
                if loading, overview == nil {
                    ProgressView("Lernplan wird vorbereitet …")
                } else if let error, overview == nil {
                    ErrorState(error) { await load() }
                } else {
                    dashboard
                }
            }
            .groupedScreen()
            .navigationTitle("Lernen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedArea == .exams {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingNewExam = true
                        } label: {
                            Label("Arbeit hinzufügen", systemImage: "plus")
                        }
                    }
                }
            }
        }
        .task { await load() }
        .task(id: dailyMinutes) { await loadPlan() }
        .sheet(isPresented: $showingNewExam) {
            NewExamView(
                api: api,
                lessons: lessons,
                subjectNames: folderNames,
                suggestions: examSuggestions
            ) { exam in
                await createExam(exam)
            }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            Picker("Lernbereich", selection: $selectedArea) {
                ForEach(Area.allCases) { area in
                    Text(area.rawValue).tag(area)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                Group {
                    switch selectedArea {
                    case .today:
                        todayPage
                    case .exams:
                        examsPage
                    case .subjects:
                        subjectsPage
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .refreshable { await load() }
        }
    }

    // MARK: - Today

    private var todayPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dein Plan für heute")
                    .font(.largeTitle.bold())
                Text("Fällige Wiederholungen, bevorstehende Arbeiten und unsichere Themen – sinnvoll gemischt.")
                    .foregroundStyle(.secondary)
            }

            timeBudget
            planHero

            if let blocks = plan?.blocks, !blocks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("So ist dein Plan aufgebaut")
                        .font(.title2.bold())
                    ForEach(blocks) { block in
                        PlanBlockRow(block: block)
                    }
                }
            }

            if !upcomingExams.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nächste Arbeiten")
                        .font(.title2.bold())
                    ForEach(upcomingExams.prefix(3)) { exam in
                        NavigationLink {
                            ExamStudyView(api: api, exam: exam, lessons: lessons, cards: cards)
                        } label: {
                            ExamCompactCard(exam: exam)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
            }

            weakConceptsSection
        }
        .padding(.top, 10)
    }

    private var timeBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wie viel Zeit hast du?")
                .font(.headline)
            Picker("Zeitbudget", selection: $dailyMinutes) {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .cardSurface()
    }

    @ViewBuilder
    private var planHero: some View {
        if let plan, !plan.cards.isEmpty {
            NavigationLink {
                ReviewView(api: api, title: "Heute lernen", mode: .review) {
                    interleaved(plan.cards)
                }
            } label: {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().fill(.white.opacity(0.18))
                        Image(systemName: "play.fill")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tagesplan starten")
                            .font(.title2.bold())
                        Text("\(plan.cards.count) Fragen · etwa \(plan.estimatedMinutes) Minuten")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.12, green: 0.42, blue: 0.98), Color(red: 0.40, green: 0.20, blue: 0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                )
                .shadow(color: Color.blue.opacity(0.22), radius: 16, y: 8)
            }
            .buttonStyle(PressableCardStyle())
        } else {
            ContentUnavailableView(
                "Heute ist nichts fällig",
                systemImage: "checkmark.seal.fill",
                description: Text("Öffne ein Fach, um neue Unterrichtsstunden als Kartensatz vorzubereiten.")
            )
            .padding(.vertical, 24)
            .cardSurface()
        }
    }

    private var weakConceptsSection: some View {
        let concepts = weakConcepts(from: cards)
        return Group {
            if !concepts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Unsichere Themen")
                        .font(.title2.bold())
                    ForEach(concepts.prefix(5), id: \.name) { concept in
                        HStack {
                            Image(systemName: "target")
                                .foregroundStyle(subjectStyle(for: concept.subject).tint.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(concept.name).font(.headline)
                                Text(concept.subject).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(concept.readinessLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .cardSurface(cornerRadius: 14)
                    }
                }
            }
        }
    }

    // MARK: - Exams

    private var examsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prüfungen")
                        .font(.largeTitle.bold())
                    Text("Echo verteilt den Stoff bis zum Termin und passt den Plan nach jeder Antwort an.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingNewExam = true
                } label: {
                    Label("Neue Arbeit", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if exams.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Arbeit", systemImage: "calendar.badge.plus")
                } description: {
                    Text(
                        "Wähle Fach, Termin und Unterrichtszeitraum. Echo stellt daraus automatisch deinen Lernstoff zusammen."
                    )
                } actions: {
                    Button("Arbeit anlegen") { showingNewExam = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 38)
                .cardSurface()
            } else {
                ForEach(upcomingExams) { exam in
                    NavigationLink {
                        ExamStudyView(api: api, exam: exam, lessons: lessons, cards: cards)
                    } label: {
                        ExamLargeCard(exam: exam)
                    }
                    .buttonStyle(PressableCardStyle())
                    .contextMenu {
                        Button("Prüfung löschen", role: .destructive) {
                            Task { await deleteExam(exam) }
                        }
                    }
                }
            }

            if !examSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("In WebUntis erkannt", systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    ForEach(examSuggestions.prefix(4)) { lesson in
                        Button {
                            showingNewExam = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(lesson.title).font(.headline)
                                    Text(lesson.date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Übernehmen").font(.callout.weight(.semibold))
                            }
                            .padding(14)
                            .cardSurface(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    // MARK: - Subjects

    private var subjectsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fächer")
                    .font(.largeTitle.bold())
                Text("Themen, Wissenslücken und einzelne Unterrichtsstunden.")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)],
                spacing: 18
            ) {
                ForEach(folders) { folder in
                    if folder.isEmpty {
                        SubjectDeckTile(
                            name: folder.name,
                            due: folder.due,
                            cardCount: folder.cardCount,
                            lessonCount: 0,
                            style: subjectStyle(for: folder.name)
                        )
                    } else {
                        NavigationLink {
                            StudySubjectView(api: api, folder: folder, cards: cards)
                        } label: {
                            SubjectDeckTile(
                                name: folder.name,
                                due: folder.due,
                                cardCount: folder.cardCount,
                                lessonCount: folder.lessons.count,
                                style: subjectStyle(for: folder.name)
                            )
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    // MARK: - Data

    private var upcomingExams: [BackendAPI.LearnExam] {
        exams.filter { $0.daysRemaining >= 0 }.sorted { $0.examDate < $1.examDate }
    }

    private var folderNames: [String] {
        folders.filter { $0.subject != nil }.map(\.name)
    }

    private var folders: [LearnFolder] {
        var bySubject = Dictionary(grouping: lessons) { lesson in
            let value = lesson.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? otherSubjectName : value
        }
        var names = Set(subjects.map(\.name))
        names.formUnion(bySubject.keys.filter { $0 != otherSubjectName })
        var result = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let subjectCards = cards.filter { $0.subject == name }
            return LearnFolder(
                name: name,
                subject: name,
                lessons: (bySubject.removeValue(forKey: name) ?? []).sortedNewestFirst,
                due: subjectCards.filter(isDueNow).count,
                cardCount: subjectCards.count
            )
        }
        let otherLessons = bySubject.removeValue(forKey: otherSubjectName) ?? []
        if !otherLessons.isEmpty {
            let otherCards = cards.filter { $0.subject == nil }
            result.append(
                LearnFolder(
                    name: otherSubjectName,
                    subject: nil,
                    lessons: otherLessons.sortedNewestFirst,
                    due: otherCards.filter(isDueNow).count,
                    cardCount: otherCards.count
                )
            )
        }
        return result
    }

    private func isDueNow(_ card: BackendAPI.LearnCard) -> Bool {
        isCardDue(card, today: LearnDay.today, answered: model.reviews.answeredIDs)
    }

    private func interleaved(_ input: [BackendAPI.LearnCard]) -> [BackendAPI.LearnCard] {
        var groups = Dictionary(grouping: input) { $0.subject ?? otherSubjectName }
        let keys = groups.keys.sorted()
        var output: [BackendAPI.LearnCard] = []
        while !groups.isEmpty {
            for key in keys {
                guard var group = groups[key], !group.isEmpty else { continue }
                output.append(group.removeFirst())
                if group.isEmpty { groups.removeValue(forKey: key) } else { groups[key] = group }
            }
        }
        return output
    }

    private func load() async {
        loading = true
        error = nil
        do {
            async let fetchedOverview = api.learnOverview()
            async let fetchedLessons = api.listLessons()
            async let fetchedCards = api.allCards()
            async let fetchedSubjects = api.timetableSubjects()
            async let fetchedExams = api.learnExams()
            let values = try await (fetchedOverview, fetchedLessons, fetchedCards, fetchedSubjects, fetchedExams)
            overview = values.0
            lessons = values.1.filter { $0.segmentCount > 0 }
            cards = values.2
            subjects = values.3
            exams = values.4
            await loadPlan()
            Task { await loadExamSuggestions() }
        } catch {
            self.error = error
        }
        loading = false
    }

    private func loadPlan() async {
        guard !loading || overview != nil else { return }
        if let fetched = try? await api.learnPlan(minutes: dailyMinutes) {
            plan = fetched
        }
    }

    private func loadExamSuggestions() async {
        let calendar = Calendar.current
        var found: [BackendAPI.Lesson] = []
        for offset in 0 ..< 6 {
            guard let date = calendar.date(byAdding: .weekOfYear, value: offset, to: Date()) else { continue }
            let start = StudyDate.iso(date)
            guard let week = try? await api.timetableWeek(start: start) else { continue }
            found.append(contentsOf: week.days.flatMap(\.lessons).filter(\.isExam))
        }
        examSuggestions = Dictionary(grouping: found, by: \.id).compactMap(\.value.first)
            .sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
    }

    private func createExam(_ newExam: BackendAPI.NewLearnExam) async {
        do {
            _ = try await api.createLearnExam(newExam)
            let existing = Set(cards.map(\.sessionId))
            for sessionId in newExam.sessionIds where !existing.contains(sessionId) {
                _ = try? await api.generateCards(sessionId: sessionId)
            }
            await load()
        } catch {
            self.error = error
        }
    }

    private func deleteExam(_ exam: BackendAPI.LearnExam) async {
        guard await (try? api.deleteLearnExam(id: exam.id)) != nil else { return }
        exams.removeAll { $0.id == exam.id }
        await loadPlan()
    }
}

private struct PlanBlockRow: View {
    let block: BackendAPI.LearnPlanBlock

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(subjectStyle(for: block.subject).tint.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(block.subject).font(.headline)
                Text(block.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(block.estimatedMinutes) min").font(.headline.monospacedDigit())
                Text("\(block.cardCount) Fragen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .cardSurface(cornerRadius: 15)
    }
}

private struct ExamCompactCard: View {
    let exam: BackendAPI.LearnExam

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.title3.bold())
                .foregroundStyle(subjectStyle(for: exam.subject).tint.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(exam.name).font(.headline)
                Text(exam.daysRemaining == 0 ? "Heute" : "Noch \(exam.daysRemaining) Tage")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ReadinessBadge(value: exam.readiness)
        }
        .padding(15)
        .cardSurface(cornerRadius: 15)
    }
}

struct ExamLargeCard: View {
    let exam: BackendAPI.LearnExam

    var body: some View {
        let style = subjectStyle(for: exam.subject)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exam.subject.uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.82))
                    Text(exam.name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
                Spacer()
                ReadinessBadge(value: exam.readiness, dark: true)
            }
            HStack {
                Label(exam.daysRemaining == 0 ? "Heute" : "Noch \(exam.daysRemaining) Tage", systemImage: "calendar")
                Spacer()
                Text("\(exam.cardCount) Fragen · \(exam.dailyMinutes) min/Tag")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [style.tint.color, style.tint.color.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct ReadinessBadge: View {
    let value: Double
    var dark = false

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(dark ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(dark ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(color.opacity(0.12)), in: Capsule())
    }

    private var label: String {
        if value <= 0 { return "Noch nicht geprüft" }
        return "\(Int((value * 100).rounded())) % bereit"
    }

    private var color: Color {
        if value >= 0.8 { return .green }
        if value >= 0.55 { return .orange }
        return .red
    }
}

private struct StudyConcept {
    let name: String
    let subject: String
    let readiness: Double

    var readinessLabel: String {
        if readiness <= 0 { return "Noch nicht geprüft" }
        if readiness < 0.45 { return "Unsicher" }
        if readiness < 0.75 { return "Fast sicher" }
        return "Sicher"
    }
}

private func weakConcepts(from cards: [BackendAPI.LearnCard]) -> [StudyConcept] {
    let grouped = Dictionary(grouping: cards) { card in
        card.concept?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? card.lessonTitle?.nonEmpty
            ?? "Allgemein"
    }
    return grouped.map { name, group in
        let values = group.map(cardReadiness)
        return StudyConcept(
            name: name,
            subject: group.first?.subject ?? otherSubjectName,
            readiness: values.reduce(0, +) / Double(max(1, values.count))
        )
    }
    .sorted { $0.readiness < $1.readiness }
}

private func cardReadiness(_ card: BackendAPI.LearnCard) -> Double {
    guard (card.reps ?? 0) > 0 else { return 0 }
    let stability = max(0, card.stability ?? Double(card.box))
    let strength = min(1, log2(stability + 2) / 6)
    let lapsePenalty = min(0.25, Double(card.lapses ?? 0) * 0.03)
    return max(0, strength - lapsePenalty)
}

private enum StudyDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func iso(_ date: Date) -> String { formatter.string(from: date) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
