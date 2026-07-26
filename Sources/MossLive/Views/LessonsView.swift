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
    @State private var actionError: String?

    private var api: BackendAPI { model.api }
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stunden")
                .searchable(text: $searchText, prompt: "Stunde suchen")
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

    @ViewBuilder
    private var content: some View {
        if archive.loading {
            ProgressView("Lade Stunden…")
                .groupedScreen()
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
        } else if query.isEmpty {
            library
        } else {
            results
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !archive.recent.isEmpty {
                    shelf("Zuletzt") {
                        lessonCard(archive.recent)
                    }
                }
                shelf("Fächer") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
                        ForEach(archive.subjects) { group in
                            NavigationLink(value: group.id) {
                                SubjectCard(group: group)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .groupedScreen()
        .refreshable { await archive.load(api: api) }
    }

    /// A search asks about lessons, not about subjects: it answers with the
    /// lessons themselves.
    @ViewBuilder
    private var results: some View {
        let items = archive.matching(query)
        if items.isEmpty {
            ContentUnavailableView.search(text: query)
                .groupedScreen()
        } else {
            ScrollView {
                lessonCard(items)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
            }
            .groupedScreen()
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
    /// hand because this page is a gallery rather than a list.
    private func lessonCard(_ items: [BackendAPI.LessonInfo]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    LessonRow(info: lesson)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
