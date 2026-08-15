import SwiftUI

struct LearnExamListView: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    @State private var exams: [BackendAPI.LearnExam] = []
    @State private var creating = false
    @State private var run: BackendAPI.LearnExamRun?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if exams.isEmpty {
                ContentUnavailableView("Keine Prüfungen", systemImage: "doc.text.magnifyingglass", description: Text("Lege eine Prüfung an oder synchronisiere WebUntis."))
            }
            ForEach(exams) { exam in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(exam.name).font(.headline); Spacer(); Text(exam.subject).foregroundStyle(Theme.accent) }
                    Text("In \(exam.daysRemaining) Tagen · \(exam.cardCount) Konzepte")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: exam.readiness)
                    Button("Probeprüfung starten") { Task { await start(exam) } }
                        .buttonStyle(.borderedProminent).disabled(exam.cardCount == 0)
                }
                .swipeActions {
                    if !exam.id.hasPrefix("webuntis-") {
                        Button("Löschen", role: .destructive) { Task { await delete(exam) } }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Prüfungen")
        .toolbar { Button("Prüfung", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { LearnExamEditorView(api: api, lessons: lessons) { exams.append($0) } }
        .fullScreenCover(item: $run) { value in LearnExamRunView(api: api, initialRun: value) }
        .task { await load() }
    }

    private func load() async { do { exams = try await api.learnExams() } catch { errorMessage = error.localizedDescription } }
    private func start(_ exam: BackendAPI.LearnExam) async { do { run = try await api.startLearnExam(id: exam.id) } catch { errorMessage = error.localizedDescription } }
    private func delete(_ exam: BackendAPI.LearnExam) async { do { try await api.deleteLearnExam(id: exam.id); exams.removeAll { $0.id == exam.id } } catch { errorMessage = error.localizedDescription } }
}

struct LearnExamEditorView: View {
    let api: BackendAPI
    let lessons: [BackendAPI.LessonInfo]
    let onCreated: (BackendAPI.LearnExam) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subject = ""
    @State private var date = Date().addingTimeInterval(7 * 86_400)
    @State private var selected = Set<String>()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Fach", text: $subject)
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                Section("Enthaltene Stunden") {
                    ForEach(lessons) { lesson in
                        Button { toggle(lesson.id) } label: {
                            HStack { Text(lesson.displayTitle); Spacer(); if selected.contains(lesson.id) { Image(systemName: "checkmark") } }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Prüfung anlegen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(name.isEmpty || subject.isEmpty) }
            }
        }
    }

    private func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func save() async {
        do {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let isoDate = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            let value = try await api.createLearnExam(name: name, subject: subject, date: isoDate, sessionIds: Array(selected))
            onCreated(value); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
