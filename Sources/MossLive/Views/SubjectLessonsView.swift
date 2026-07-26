import SwiftUI

/// Everything recorded in one subject, newest first, cut into months.
///
/// This is the level where dates belong: inside Mathematik, "Juli 2026" tells
/// you where you are. At the top of the archive it only told you that time
/// passes.
struct SubjectLessonsView: View {
    let archive: LessonArchive
    let api: BackendAPI
    let subjectID: String

    @State private var months: [MonthGroup] = []
    @State private var actionError: String?

    var body: some View {
        List {
            ForEach(months) { month in
                Section {
                    ForEach(month.lessons) { lesson in
                        NavigationLink {
                            LessonDetailView(api: api, info: lesson)
                        } label: {
                            LessonRow(info: lesson)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { actionError = await archive.delete(lesson, api: api) }
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(month.title)
                }
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(archive.group(id: subjectID)?.title ?? "Fach")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if months.isEmpty {
                ContentUnavailableView {
                    Label("Keine Stunden mehr", systemImage: "graduationcap")
                } description: {
                    Text("In diesem Fach ist nichts mehr gespeichert.")
                }
                .groupedScreen()
            }
        }
        // Grouped when the archive changes — a deletion, a refresh — and not
        // once per redraw.
        .onChange(of: archive.lessons.count, initial: true) { regroup() }
        .alert(
            "Löschen fehlgeschlagen",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func regroup() {
        let lessons = archive.group(id: subjectID)?.lessons ?? []
        let calendar = Calendar.current
        months = Dictionary(grouping: lessons) { lesson in
            calendar.date(from: calendar.dateComponents([.year, .month], from: lesson.startedAt))
                ?? lesson.startedAt
        }
        .map { MonthGroup(month: $0.key, lessons: $0.value) }
        .sorted { $0.month > $1.month }
    }
}

struct MonthGroup: Identifiable {
    let month: Date
    let lessons: [BackendAPI.LessonInfo]

    var id: Date { month }
    var title: String { month.formatted(.dateTime.month(.wide).year()) }
}
