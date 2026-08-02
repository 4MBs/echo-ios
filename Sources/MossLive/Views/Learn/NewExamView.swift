import SwiftUI

/// Entering an exam: four fields, and a suggestion from the timetable that
/// actually fills them in.
///
/// The form it replaces had eight fields, two of which competed with each other
/// (a per-exam daily budget beside the global one) and one of which — "Ziel,
/// z. B. Note 2" — was collected, sent and never shown anywhere. The WebUntis
/// suggestions sat on the exam list, and tapping one opened this form empty.
struct NewExamView: View {
    let api: BackendAPI
    let store: LearnStore
    let defaultMinutes: Int
    let onSaved: @MainActor (BackendAPI.LearnExam) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var subject = ""
    @State private var examDate = Date()
    @State private var scopeStart = Date()
    @State private var name = ""
    @State private var suggestions: [BackendAPI.Lesson] = []
    @State private var selected = Set<String>()
    @State private var saving = false
    @State private var failure: String?

    /// Six weeks back is roughly what one written paper covers, and it is the
    /// number the form starts on so that "Stoff ab" is usually already right.
    private static let defaultScopeDays = -42

    var body: some View {
        NavigationStack {
            Form {
                if let suggestion = suggestions.first {
                    Section {
                        SuggestionRow(lesson: suggestion) { apply(suggestion) }
                    } header: {
                        Text("Aus deinem Stundenplan")
                    }
                }

                Section {
                    Picker("Fach", selection: $subject) {
                        ForEach(subjectNames, id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("Termin", selection: $examDate, in: Date()..., displayedComponents: .date)
                    DatePicker("Stoff ab", selection: $scopeStart, in: ...examDate, displayedComponents: .date)
                    TextField("Name", text: $name, prompt: Text("Klassenarbeit"))
                } footer: {
                    Text("Echo nimmt alle Stunden aus diesem Zeitraum. Neue Stunden schlägt es dir später vor.")
                }

                Section {
                    NavigationLink {
                        ExamScopeList(
                            subject: subject,
                            lessons: matchingLessons,
                            selected: $selected
                        )
                    } label: {
                        LabeledContent("Stunden", value: selectionLabel)
                    }
                    .disabled(matchingLessons.isEmpty)
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Arbeit eintragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Trägt ein …" : "Eintragen") { save() }
                        .disabled(saving || subject.isEmpty)
                }
            }
            .onAppear(perform: prepare)
            .task { await loadContext() }
            .onChange(of: subject) { _, _ in selectMatching() }
            // "Stoff ab" follows the exam date while it is still the default six
            // weeks before it, and stops following the moment it is moved by
            // hand. Derived from the old value rather than from a "touched"
            // flag, which every programmatic write would otherwise trip.
            .onChange(of: examDate) { oldDate, newDate in
                if Calendar.current.isDate(scopeStart, inSameDayAs: Self.defaultScope(before: oldDate)) {
                    scopeStart = Self.defaultScope(before: newDate)
                }
                selectMatching()
            }
            .onChange(of: scopeStart) { _, _ in selectMatching() }
        }
    }

    // MARK: - What is on offer

    private var subjectNames: [String] {
        var names = Set(store.lessons.compactMap(\.subject))
        names.formUnion(store.exams.map(\.subject))
        if !subject.isEmpty { names.insert(subject) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var matchingLessons: [BackendAPI.LessonInfo] {
        store.lessons
            .filter { $0.subject == subject && $0.startedAt >= scopeStart && $0.startedAt <= examDate }
            .sortedNewestFirst
    }

    private var selectionLabel: String {
        let count = selected.count
        if matchingLessons.isEmpty { return "Keine Aufnahmen im Zeitraum" }
        return count == 1 ? "1 ausgewählt" : "\(count) ausgewählt"
    }

    // MARK: - Setting up

    private func prepare() {
        guard subject.isEmpty else { return }
        examDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
        scopeStart = Self.defaultScope(before: examDate)
        subject = subjectNames.first ?? ""
        selectMatching()
    }

    private static func defaultScope(before date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: defaultScopeDays, to: date) ?? date
    }

    /// The archive, and the exams the timetable knows about. Both happen here
    /// rather than on Heute: six week requests to WebUntis for a suggestion
    /// belong to the moment the student is actually entering an exam.
    private func loadContext() async {
        await store.refreshLessons(api: api)
        if subject.isEmpty { prepare() }
        suggestions = await Self.timetableExams(api: api)
        selectMatching()
    }

    private static func timetableExams(api: BackendAPI) async -> [BackendAPI.Lesson] {
        var found: [BackendAPI.Lesson] = []
        let calendar = Calendar.current
        for offset in 0 ..< 6 {
            guard let date = calendar.date(byAdding: .weekOfYear, value: offset, to: Date()),
                  let week = try? await api.timetableWeek(start: LearnDay.string(date))
            else { continue }
            found.append(contentsOf: week.days.flatMap(\.lessons).filter(\.isExam))
        }
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.id).inserted }
            .filter { ($0.startDate ?? .distantPast) >= Date() }
            .sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
    }

    private func selectMatching() {
        selected = Set(matchingLessons.map(\.id))
    }

    private func apply(_ suggestion: BackendAPI.Lesson) {
        subject = suggestion.subjectLong ?? suggestion.subject
        name = "Klassenarbeit"
        if let date = suggestion.startDate { examDate = date }
        scopeStart = Self.defaultScope(before: examDate)
        selectMatching()
    }

    // MARK: - Saving

    private func save() {
        saving = true
        failure = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let exam = BackendAPI.NewLearnExam(
            name: trimmed.isEmpty ? "Klassenarbeit" : trimmed,
            subject: subject,
            examDate: LearnDay.string(examDate),
            scopeStart: LearnDay.string(scopeStart),
            scopeEnd: LearnDay.string(examDate),
            // One budget for the whole app; the per-exam field the server still
            // requires is fed from it.
            dailyMinutes: defaultMinutes,
            target: nil,
            sessionIds: Array(selected)
        )
        let client = api
        let withCards = Set(store.cards.map(\.sessionId))
        Task {
            do {
                let created = try await client.createLearnExam(exam)
                saving = false
                await onSaved(created)
                dismiss()
                // Writing the questions for a lesson is one AI call per lesson
                // and can take a minute each. The exam exists either way, so
                // this runs on after the sheet is gone rather than holding it
                // open; the lesson page shows the same state per lesson.
                let missing = exam.sessionIds.filter { !withCards.contains($0) }
                guard !missing.isEmpty else { return }
                Task {
                    for id in missing {
                        _ = try? await client.generateCards(sessionId: id)
                    }
                }
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}

/// The timetable's own answer to "when is the next exam", with the one control
/// that makes it worth showing.
private struct SuggestionRow: View {
    let lesson: BackendAPI.Lesson
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.subjectLong ?? lesson.subject)
                    .font(.body)
                Text(dateLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Übernehmen", action: onApply)
                .buttonStyle(.bordered)
        }
        .frame(minHeight: 44)
    }

    private var dateLine: String {
        guard let date = lesson.startDate else { return lesson.date }
        return "\(LearnDay.short(date)) · \(lesson.start)"
    }
}
