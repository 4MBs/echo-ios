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

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var months: [MonthGroup] = []
    @State private var title = "Fach"
    @State private var actionError: String?

    var body: some View {
        List {
            ForEach(months) { month in
                Section {
                    ForEach(Array(month.lessons.enumerated()), id: \.element.id) { index, lesson in
                        NavigationLink {
                            LessonDetailView(api: api, info: lesson)
                        } label: {
                            LessonRow(info: lesson)
                        }
                        // Ours, so a cancelled swipe cannot leave the row
                        // square-cornered on the way back.
                        .listRowBackground(
                            GroupedRowBackground(
                                isFirst: index == 0,
                                isLast: index == month.lessons.count - 1
                            )
                        )
                        .swipeActions(edge: .trailing) {
                            if model.connectivity.isOnline {
                                Button(role: .destructive) {
                                    Task { actionError = await archive.delete(lesson, api: api) }
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Regrouped when the archive changes — a deletion, a refresh — and not
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
        if let current = archive.group(id: subjectID)?.title {
            title = current
        }
        // The last lesson in a subject takes the subject with it: staying on a
        // page for something that no longer exists is worse than going back.
        guard !lessons.isEmpty else {
            months = []
            dismiss()
            return
        }
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
