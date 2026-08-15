import SwiftUI

struct LearnExamListView: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    @State private var exams: [BackendAPI.LearnExam] = []
    @State private var creating = false
    @State private var editing: BackendAPI.LearnExam?
    @State private var run: BackendAPI.LearnExamRun?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if exams.isEmpty {
                ContentUnavailableView(
                    "Keine Prüfungen",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Lege eine Prüfung an oder synchronisiere WebUntis.")
                )
            }
            ForEach(exams) { exam in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(exam.name).font(.headline); Spacer(); Text(exam.subject).foregroundStyle(Theme.accent)
                    }
                    Text("In \(exam.daysRemaining) Tagen · \(exam.cardCount) Konzepte")
                        .font(.caption).foregroundStyle(.secondary)
                    if let readiness = exam.readiness {
                        ProgressView(value: readiness)
                        Text("Prüfungsbereitschaft \(readiness.formatted(.percent))").font(.caption)
                    } else {
                        Text("Noch nicht genug Abrufdaten für eine Bereitschaft").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(exam.activeRunId == nil ? "Probeprüfung starten" : "Probeprüfung fortsetzen") {
                        Task { await start(exam) }
                    }
                    .buttonStyle(.borderedProminent).disabled(exam.cardCount == 0)
                }
                .swipeActions {
                    Button("Bearbeiten") { editing = exam }.tint(.blue)
                    if !exam.id.hasPrefix("webuntis-") {
                        Button("Löschen", role: .destructive) { Task { await delete(exam) } }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Prüfungen")
        .toolbar { Button("Prüfung", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) {
            LearnExamEditorView(api: api, lessons: lessons, existing: nil) { exams.append($0) }
        }
        .sheet(item: $editing) { exam in
            LearnExamEditorView(api: api, lessons: lessons, existing: exam) { updated in
                if let index = exams.firstIndex(where: { $0.id == updated.id }) { exams[index] = updated }
            }
        }
        .fullScreenCover(item: $run, onDismiss: { Task { await load() } }) { value in
            LearnExamRunView(api: api, initialRun: value)
        }
        .task { await load() }
    }

    private func load() async {
        do { exams = try await api.learnExams() } catch { errorMessage = error.localizedDescription }
    }

    private func start(_ exam: BackendAPI.LearnExam) async {
        do {
            if let runId = exam.activeRunId { run = try await api.learnExamRun(id: runId) }
            else { run = try await api.startLearnExam(id: exam.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ exam: BackendAPI.LearnExam) async {
        do { try await api.deleteLearnExam(id: exam.id); exams.removeAll { $0.id == exam.id } } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LearnExamEditorView: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    let existing: BackendAPI.LearnExam?
    let onSaved: (BackendAPI.LearnExam) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subject = ""
    @State private var date = Date().addingTimeInterval(7 * 86400)
    @State private var selected = Set<String>()
    @State private var dailyMinutes = 30
    @State private var errorMessage: String?

    init(
        api: BackendAPI,
        lessons: [BackendAPI.LessonInfo],
        existing: BackendAPI.LearnExam?,
        onSaved: @escaping (BackendAPI.LearnExam) -> Void
    ) {
        self.api = api; self.lessons = lessons; self.existing = existing; self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _subject = State(initialValue: existing?.subject ?? "")
        _selected = State(initialValue: Set(existing?.sessionIds ?? []))
        _dailyMinutes = State(initialValue: existing?.dailyMinutes ?? 30)
        if let value = existing?.examDate, let parsed = Self.parseDate(value) { _date = State(initialValue: parsed) }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Fach", text: $subject)
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                Stepper("Täglich \(dailyMinutes) Minuten", value: $dailyMinutes, in: 5 ... 120, step: 5)
                Section("Enthaltene Stunden") {
                    ForEach(lessons) { lesson in
                        Button { toggle(lesson.id) } label: {
                            HStack {
                                Text(lesson.displayTitle); Spacer(); if selected
                                    .contains(lesson.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "Prüfung anlegen" : "Prüfung bearbeiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { Task { await save() } }.disabled(name.isEmpty || subject.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func save() async {
        do {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let isoDate = String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
            let value: BackendAPI.LearnExam = if let existing {
                try await api.updateLearnExam(
                    existing,
                    name: name,
                    subject: subject,
                    date: isoDate,
                    sessionIds: Array(selected),
                    dailyMinutes: dailyMinutes
                )
            } else {
                try await api.createLearnExam(
                    name: name,
                    subject: subject,
                    date: isoDate,
                    sessionIds: Array(selected),
                    dailyMinutes: dailyMinutes
                )
            }
            onSaved(value); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private static func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
