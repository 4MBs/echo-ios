import SwiftUI

/// "Stunden": the archive as one timeline with a section per school day — the
/// shape Fotos and Sprachmemos give a run of days.
///
/// It used to be a folder per day that had to be opened first, which cost a tap
/// on every lesson and, worse, swallowed the search: a hit was regrouped into
/// its day, so searching handed you a folder to open instead of the lesson you
/// asked for. Sections say the same thing about the day without hiding what is
/// inside it.
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var loadError: Error?
    @State private var subjectFilter: String?
    @State private var searchText = ""
    @State private var dayToDelete: Date?
    @State private var actionError: String?

    private var api: BackendAPI { model.api }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !query.isEmpty }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stunden")
                .searchable(text: $searchText, prompt: "Suchen")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        filterMenu
                    }
                }
        }
        .task { await load() }
    }

    private var subjects: [String] {
        Array(Set(lessons.compactMap(\.subject))).sorted()
    }

    private var filtered: [BackendAPI.LessonInfo] {
        var result = lessons
        if let subjectFilter {
            result = result.filter { $0.subject == subjectFilter }
        }
        if isSearching {
            result = result.filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.subject ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.teacher ?? "").localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

    /// One section per calendar day, newest day first, lessons inside in the
    /// order they were taught.
    private var days: [(day: Date, lessons: [BackendAPI.LessonInfo])] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.startedAt < $1.startedAt }) }
    }

    /// A search is a question about lessons, not about days: the results are
    /// one flat list, most recent first.
    private var results: [BackendAPI.LessonInfo] {
        filtered.sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Lade Stunden…")
                .groupedScreen()
        } else if lessons.isEmpty, let loadError {
            ErrorState(loadError) { await load() }
                .groupedScreen()
        } else if lessons.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Stunden", systemImage: "calendar")
            } description: {
                Text("Nimm eine Stunde auf, dann erscheint sie hier.")
            }
            .groupedScreen()
        } else {
            archive
        }
    }

    private var archive: some View {
        List {
            if isSearching {
                Section {
                    rows(results)
                }
            } else {
                ForEach(days, id: \.day) { entry in
                    Section {
                        rows(entry.lessons)
                    } header: {
                        DayHeader(
                            day: entry.day,
                            count: entry.lessons.count,
                            canDelete: model.connectivity.isOnline
                        ) {
                            dayToDelete = entry.day
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .overlay {
            if isSearching, results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .groupedScreen()
            }
        }
        .confirmationDialog(
            "Alle Stunden dieses Tages löschen?",
            isPresented: Binding(
                get: { dayToDelete != nil },
                set: { if !$0 { dayToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Tag löschen", role: .destructive) {
                if let day = dayToDelete {
                    Task { await deleteDay(day) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
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

    private func rows(_ items: [BackendAPI.LessonInfo]) -> some View {
        ForEach(items) { lesson in
            NavigationLink {
                LessonDetailView(api: api, info: lesson)
            } label: {
                LessonRow(info: lesson)
            }
            .swipeActions(edge: .trailing) {
                // Deleting is the server's copy to delete, so it waits for the
                // server rather than half-happening here.
                if model.connectivity.isOnline {
                    Button(role: .destructive) {
                        Task { await delete(lesson) }
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// The subject filter, and nothing else. Sorting used to share this menu,
    /// but an archive reads newest-first and nobody sets that twice.
    private var filterMenu: some View {
        Menu {
            Picker("Fach", selection: $subjectFilter) {
                Text("Alle Fächer").tag(String?.none)
                ForEach(subjects, id: \.self) { subject in
                    Text(subject).tag(String?.some(subject))
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: subjectFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    private func load() async {
        let key = OfflineCache.Key.lessons
        if lessons.isEmpty, let cached = OfflineCache.load([BackendAPI.LessonInfo].self, key: key) {
            lessons = cached
        }
        loading = lessons.isEmpty
        loadError = nil
        do {
            let fresh = try await api.listLessons().filter { $0.segmentCount > 0 }
            lessons = fresh
            OfflineCache.save(fresh, as: key)
        } catch {
            // The archive is a list of what was recorded on this iPad. Keeping
            // it readable without the server is the whole point of storing it.
            if lessons.isEmpty { loadError = error }
        }
        loading = false
    }

    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            withAnimation(.snappy) {
                lessons.removeAll { $0.id == lesson.id }
            }
        } catch {
            actionError = error.localizedDescription
            await load()
        }
    }

    private func deleteDay(_ day: Date) async {
        let targets = lessons.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
        do {
            for lesson in targets {
                try await api.deleteLesson(id: lesson.id)
                BackendAPI.purgeCachedAudio(id: lesson.id)
            }
            withAnimation(.snappy) {
                lessons.removeAll { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
            }
        } catch {
            actionError = error.localizedDescription
            await load()
        }
    }
}

/// A day's section header: what day it was, how much was recorded, and the one
/// action that belongs to a whole day rather than to a lesson.
struct DayHeader: View {
    let day: Date
    let count: Int
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(count == 1 ? "1 Stunde" : "\(count) Stunden")
            if canDelete {
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Tag löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Aktionen für \(title)")
            }
        }
    }

    /// Relative for the days a school week actually talks about, absolute
    /// after that — and only then does the year earn its place.
    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Heute" }
        if calendar.isDateInYesterday(day) { return "Gestern" }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
    }
}
