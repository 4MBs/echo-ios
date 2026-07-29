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
    /// The subject whose folder was tapped while it had nothing in it.
    @State private var emptySubject: String?

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
                .emptySubjectNotice($emptySubject) { subject in
                    "In \(subject) ist noch nichts aufgenommen. "
                        + "Nimm eine Stunde in diesem Fach auf, dann erscheint sie hier."
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
                    folderCard(folder)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .animation(.snappy, value: sort)
        }
        .groupedScreen()
        .refreshable { await load() }
    }

    /// A link when the folder has something in it, a button that says so when it
    /// does not — the same bargain the Lernen grid makes, and for the same
    /// reason: an empty folder is drawn because the subject exists, but opening
    /// it would land on a screen with one sentence on it.
    @ViewBuilder
    private func folderCard(_ folder: SubjectFolder) -> some View {
        if folder.lessons.isEmpty {
            Button {
                emptySubject = folder.name
            } label: {
                tile(folder)
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityHint("Noch keine Aufnahmen")
        } else {
            NavigationLink {
                SubjectView(api: api, folder: folder) { await load() }
            } label: {
                tile(folder)
            }
            .buttonStyle(PressableCardStyle())
        }
    }

    private func tile(_ folder: SubjectFolder) -> some View {
        SubjectFolderTile(
            name: folder.name,
            count: folder.lessons.count,
            style: subjectStyle(for: folder.name)
        )
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
        let rows = ordered
        let first = rows.first?.id
        let last = rows.last?.id
        return List {
            ForEach(rows) { lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    LessonRow(info: lesson)
                }
                .listRowBackground(
                    rowBackground(isFirst: lesson.id == first, isLast: lesson.id == last)
                )
            }
            .onDelete { offsets in
                let targets = offsets.map { rows[$0] }
                Task {
                    for lesson in targets {
                        await delete(lesson)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// The row's rounded background, drawn here rather than left to the list.
    ///
    /// An inset-grouped list does not round the row — it rounds a background
    /// *behind* the row, and which of its corners get rounded depends on where
    /// the row sits in its section. While a swipe is in flight the swipe
    /// container re-lays that background out without re-resolving the position,
    /// so the corners go square for the length of the drag and come back when it
    /// settles. That is the squared-off box; it is a SwiftUI bug, still open on
    /// iOS 26, and reported as a regression from iOS 18.
    ///
    /// A `listRowBackground` occupies the same anchored slot but belongs to us,
    /// so it keeps its corners for the whole gesture. What it gives up is the
    /// iOS 26 flourish where Mail rounds a row *further* to match the swipe
    /// buttons — which is the very thing that is broken here, so there is not
    /// much to give up.
    private func rowBackground(isFirst: Bool, isLast: Bool) -> some View {
        let radius: CGFloat = 12
        return UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous
        )
        // The colour an inset-grouped row actually is, so this is the same
        // surface in both appearances rather than a white that goes wrong at
        // night.
        .fill(Color(.secondarySystemGroupedBackground))
    }

    /// Gone from the list first, restored if the server refuses.
    ///
    /// The row used to wait for a round trip before it moved, so letting go of a
    /// swipe was followed by a pause with the row sitting half open — over
    /// Tailscale, a long one. No animation can be made to feel smooth with a
    /// network request in front of it.
    ///
    /// The removal itself is not animated here, and not because nobody tried:
    /// `List` manages its own insert and delete animations and ignores
    /// `withAnimation`, `.animation(_:value:)` and `.transition` alike. The
    /// `withAnimation` that used to wrap this line did nothing at all.
    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        let previous = lessons
        lessons.removeAll { $0.id == lesson.id }
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            await onChanged()
        } catch {
            lessons = previous
            actionError = error.localizedDescription
        }
    }
}
