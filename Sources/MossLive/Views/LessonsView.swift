import SwiftUI

/// "Stunden": the archive as a grid of folders, one per subject.
///
/// The folders come from the timetable rather than from the archive, so a
/// subject has its place before its first recording does and an empty archive
/// still looks like your own school week. "Sonstige" is the catch-all for
/// everything recorded while no lesson was running — the holidays, an evening,
/// a free period — which is the one folder that cannot come from WebUntis.
///
/// A folder opens the subject's recordings by day; a lesson opens
/// Zusammenfassung/Transkript. Abfragen lives in the Lernen tab.
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var catalogue: [BackendAPI.SubjectInfo] = []
    @State private var loading = true
    @State private var loadError: Error?
    @State private var sort: FolderSort = .name
    @State private var searchText = ""

    private var api: BackendAPI { model.api }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stunden")
                .searchable(text: $searchText, prompt: "Fach oder Stunde suchen")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
        }
        .task { await load() }
    }

    /// How the grid is laid out. `.name` is the default because a folder you
    /// are looking for is one you already know the name of.
    enum FolderSort: String, CaseIterable, Identifiable {
        case name, recent, count

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .recent: "Zuletzt aufgenommen"
            case .count: "Anzahl Aufnahmen"
            }
        }
    }

    // MARK: - Folders

    /// The grid's folders: every subject of the school year, plus any subject
    /// only the archive still remembers, plus Sonstige.
    private var folders: [SubjectFolder] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? lessons : lessons.filter { $0.matches(query) }

        var filed: [String: [BackendAPI.LessonInfo]] = [:]
        var unfiled: [BackendAPI.LessonInfo] = []
        for lesson in matching {
            let subject = (lesson.subject ?? "").trimmingCharacters(in: .whitespaces)
            if subject.isEmpty {
                unfiled.append(lesson)
            } else {
                filed[subject, default: []].append(lesson)
            }
        }

        // A search narrows the grid to folders that answer it — either by name,
        // or by holding a recording that does.
        var names = Set(filed.keys)
        if query.isEmpty {
            names.formUnion(catalogue.map(\.name))
        } else {
            names.formUnion(catalogue.map(\.name).filter { $0.localizedCaseInsensitiveContains(query) })
        }

        var out = names.map { name in
            SubjectFolder(name: name, lessons: (filed[name] ?? []).sortedNewestFirst, isOther: false)
        }
        out.sort(by: sort.areInOrder)

        let wantsOther = query.isEmpty
            || !unfiled.isEmpty
            || otherSubjectName.localizedCaseInsensitiveContains(query)
        if wantsOther {
            out.append(SubjectFolder(name: otherSubjectName, lessons: unfiled.sortedNewestFirst, isOther: true))
        }
        return out
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Lade Stunden…")
                .groupedScreen()
        } else if lessons.isEmpty, catalogue.isEmpty, let loadError {
            ErrorState(loadError) { await load() }
                .groupedScreen()
        } else if lessons.isEmpty, catalogue.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Stunden", systemImage: "folder")
            } description: {
                Text(
                    "Nimm eine Stunde auf, dann erscheint sie hier. "
                        + "Mit verbundenem Stundenplan steht für jedes Fach schon ein Ordner bereit."
                )
            }
            .groupedScreen()
        } else if folders.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .groupedScreen()
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)],
                spacing: 22
            ) {
                ForEach(folders) { folder in
                    NavigationLink {
                        SubjectView(api: api, folder: folder) { await load() }
                    } label: {
                        SubjectFolderTile(
                            name: folder.name,
                            count: folder.lessons.count,
                            style: subjectStyle(for: folder.name)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .animation(.snappy, value: sort)
        }
        .groupedScreen()
        .refreshable { await load() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortierung", selection: $sort) {
                ForEach(FolderSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label("Sortieren", systemImage: "arrow.up.arrow.down.circle")
        }
    }

    // MARK: - Loading

    private func load() async {
        if lessons.isEmpty,
           let cached = OfflineCache.load([BackendAPI.LessonInfo].self, key: OfflineCache.Key.lessons) {
            lessons = cached
        }
        if catalogue.isEmpty,
           let cached = OfflineCache.load(
               [BackendAPI.SubjectInfo].self,
               key: OfflineCache.Key.timetableSubjects
           ) {
            catalogue = cached
        }
        loading = lessons.isEmpty && catalogue.isEmpty
        loadError = nil

        async let recorded = api.listLessons()
        async let subjects = api.timetableSubjects()

        do {
            let archive = try await recorded
            let usable = archive.filter { $0.segmentCount > 0 }
            lessons = usable
            OfflineCache.save(usable, as: OfflineCache.Key.lessons)
        } catch {
            // The archive is a list of what was recorded on this iPad. Keeping
            // it readable without the server is the whole point of storing it.
            if lessons.isEmpty { loadError = error }
        }
        // The catalogue is the nicety, not the archive: a server with no
        // timetable connected — or one too old to know the endpoint — simply
        // leaves the grid to the subjects that were actually recorded. It has
        // to be awaited on every path, or the fetch is cancelled on the way out.
        if let fresh = try? await subjects, !fresh.isEmpty {
            catalogue = fresh
            OfflineCache.save(fresh, as: OfflineCache.Key.timetableSubjects)
        }
        loading = false
    }
}

// MARK: - The folder model

/// One folder in the Stunden grid: a subject, and what is filed under it.
struct SubjectFolder: Identifiable {
    let name: String
    let lessons: [BackendAPI.LessonInfo]
    /// The catch-all. It is not a subject, so it is appended after the sort
    /// rather than taking part in one and never competes alphabetically.
    let isOther: Bool

    /// Prefixed out of the way so a real subject actually called "Sonstige"
    /// could still have its own folder beside the catch-all.
    var id: String { isOther ? "\u{1}sonstige" : name }

    var latest: Date? { lessons.map(\.startedAt).max() }
}

extension LessonsView.FolderSort {
    /// Empty folders always trail the ones with something in them: sorting by
    /// what you last recorded should not put fourteen untouched subjects on top.
    func areInOrder(_ lhs: SubjectFolder, _ rhs: SubjectFolder) -> Bool {
        switch self {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .recent:
            switch (lhs.latest, rhs.latest) {
            case let (left?, right?): return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .count:
            if lhs.lessons.count != rhs.lessons.count {
                return lhs.lessons.count > rhs.lessons.count
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension BackendAPI.LessonInfo {
    /// Free-text match over everything a lesson is named by.
    func matches(_ query: String) -> Bool {
        (title ?? "").localizedCaseInsensitiveContains(query)
            || (subject ?? "").localizedCaseInsensitiveContains(query)
            || (teacher ?? "").localizedCaseInsensitiveContains(query)
            || (room ?? "").localizedCaseInsensitiveContains(query)
    }
}

extension [BackendAPI.LessonInfo] {
    var sortedNewestFirst: [BackendAPI.LessonInfo] {
        sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Inside a folder

/// One subject: its recordings, newest first, each row leading with its date
/// and the opening of its summary.
struct SubjectView: View {
    let api: BackendAPI
    let folder: SubjectFolder
    let onChanged: () async -> Void

    @State private var lessons: [BackendAPI.LessonInfo]
    @State private var actionError: String?

    init(api: BackendAPI, folder: SubjectFolder, onChanged: @escaping () async -> Void) {
        self.api = api
        self.folder = folder
        self.onChanged = onChanged
        _lessons = State(initialValue: folder.lessons)
    }

    /// Newest first, and flat: every row now leads with its own date, so a
    /// header above it saying the same date again is one line of chrome per
    /// lesson in a list where most days hold exactly one.
    private var ordered: [BackendAPI.LessonInfo] {
        lessons.sortedNewestFirst
    }

    var body: some View {
        Group {
            if lessons.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Aufnahmen", systemImage: subjectStyle(for: folder.name).symbol)
                } description: {
                    Text(folder.isOther
                        ? "Aufnahmen außerhalb des Stundenplans landen hier."
                        : "Nimm eine Stunde in \(folder.name) auf, dann erscheint sie hier.")
                }
                .groupedScreen()
            } else {
                list
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !lessons.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .alert(
            "Stunde konnte nicht gelöscht werden",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var list: some View {
        List {
            ForEach(ordered) { lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    LessonRow(info: lesson)
                }
            }
            .onDelete { offsets in
                let targets = offsets.map { ordered[$0] }
                Task {
                    for lesson in targets {
                        await delete(lesson)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            withAnimation(.snappy) {
                lessons.removeAll { $0.id == lesson.id }
            }
            await onChanged()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
