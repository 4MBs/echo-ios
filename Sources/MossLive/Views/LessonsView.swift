import SwiftUI

/// "Stunden": a library of subjects, not a pile of days.
///
/// School is organised by subject — you revise Mathematik, you do not revise
/// "Dienstag" — so the archive's top level is the subjects themselves, with
/// the last few recordings on a shelf above them for the common case of
/// wanting the lesson that just happened. Days survive one level down, inside
/// a subject, where they are a detail rather than the filing system.
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var archive = LessonArchive()
    @State private var searchText = ""
    @State private var subjectToDelete: SubjectGroup?
    @State private var actionError: String?

    private var api: BackendAPI { model.api }
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            content
                // The page arrives rather than appearing: loading, empty and
                // library are three states of one screen.
                .animation(.easeInOut(duration: 0.25), value: archive.loading)
                .navigationTitle("Stunden")
                .navigationDestination(for: String.self) { subject in
                    SubjectLessonsView(archive: archive, api: api, subjectID: subject)
                }
                .alert(
                    "Löschen fehlgeschlagen",
                    isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(actionError ?? "")
                }
        }
        .task { await archive.load(api: api) }
    }

    /// The search field belongs to the library, not to the tab: with nothing
    /// stored there is nothing to search, and a field that can only ever come
    /// up empty is furniture. It is attached to the library itself, so it
    /// arrives with the first lesson and leaves with the last.
    @ViewBuilder
    private var content: some View {
        if archive.loading {
            ProgressView("Lade Stunden…")
                .groupedScreen()
                .transition(.opacity)
        } else if archive.isEmpty, let error = archive.loadError {
            ErrorState(error) { await archive.load(api: api) }
                .groupedScreen()
        } else if archive.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Stunden", systemImage: "graduationcap")
            } description: {
                Text("Nimm eine Stunde auf, dann erscheint sie hier.")
            }
            .groupedScreen()
            .transition(.opacity)
        } else {
            library
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var library: some View {
        // Once per redraw, not once per section: the overlay needs the same
        // answer the page does.
        let matches = query.isEmpty ? [] : archive.matching(query)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if query.isEmpty {
                    if !archive.recent.isEmpty {
                        shelf("Zuletzt") {
                            lessonCard(archive.recent)
                        }
                    }
                    shelf("Fächer") {
                        subjectGrid
                    }
                } else {
                    lessonCard(matches)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .groupedScreen()
        .refreshable { await archive.load(api: api) }
        .searchable(text: $searchText, prompt: "Stunde suchen")
        .overlay {
            if !query.isEmpty, matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .groupedScreen()
            }
        }
        .animation(.snappy, value: query.isEmpty)
        .confirmationDialog(
            subjectToDelete.map { "Alle Stunden in \($0.title) löschen?" } ?? "",
            isPresented: Binding(
                get: { subjectToDelete != nil },
                set: { if !$0 { subjectToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let group = subjectToDelete {
                    Task { actionError = await archive.deleteSubject(id: group.id, api: api) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var subjectGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
            ForEach(archive.subjects) { group in
                NavigationLink(value: group.id) {
                    SubjectCard(group: group)
                }
                .buttonStyle(.card)
                .contextMenu {
                    // Deleting is the server's copy to delete, so it is not
                    // offered when the server cannot be reached.
                    if model.connectivity.isOnline {
                        Button(role: .destructive) {
                            subjectToDelete = group
                        } label: {
                            Label("Fach löschen", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func shelf(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    /// Lessons as rows on one inset card — the grouped-list surface, built by
    /// hand because this page is a gallery rather than a list. The chevron is
    /// drawn here for the same reason: a list would have supplied it, and
    /// without it the rows read as labels rather than as somewhere to go.
    private func lessonCard(_ items: [BackendAPI.LessonInfo]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    HStack(spacing: 10) {
                        LessonRow(info: lesson)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.card)
                if index < items.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .cardSurface(cornerRadius: 16)
    }
}

/// One subject in the library: its glyph at tile size, its name, and how much
/// of it there is.
struct SubjectCard: View {
    let group: SubjectGroup

    var body: some View {
        let style = subjectStyle(for: group.id.isEmpty ? nil : group.id)
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(style.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 18)
    }

    private var subtitle: String {
        guard let last = group.lastRecorded else { return group.countLabel }
        return "\(group.countLabel) · \(relative(last))"
    }

    private func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "heute" }
        if calendar.isDateInYesterday(date) { return "gestern" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
