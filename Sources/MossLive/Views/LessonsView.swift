import SwiftUI

/// "Stunden": the archive grouped into one folder per school day. A folder
/// opens the day's lessons; a lesson opens Zusammenfassung/Transkript.
/// Abfragen lives in the Lernen tab.
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var subjectFilter: String?
    @State private var newestFirst = true
    @State private var searchText = ""
    @State private var dayToDelete: Date?
    @State private var actionError: String?

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

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

    /// One folder per calendar day, lessons inside in chronological order.
    private var days: [(day: Date, lessons: [BackendAPI.LessonInfo])] {
        var filtered = lessons
        if let subjectFilter {
            filtered = filtered.filter { $0.subject == subjectFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            filtered = filtered.filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.subject ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.teacher ?? "").localizedCaseInsensitiveContains(query)
            }
        }
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped
            .sorted { newestFirst ? $0.key > $1.key : $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.startedAt < $1.startedAt }) }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Lade Stunden…")
                .groupedScreen()
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }
                .groupedScreen()
        } else if lessons.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Stunden", systemImage: "books.vertical")
            } description: {
                Text("Nimm eine Stunde auf, dann erscheint sie hier.")
            }
            .groupedScreen()
        } else {
            List {
                ForEach(days, id: \.day) { entry in
                    NavigationLink {
                        DayView(api: api, day: entry.day, lessons: entry.lessons) {
                            await load()
                        }
                    } label: {
                        DayRow(day: entry.day, lessons: entry.lessons)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            dayToDelete = entry.day
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
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
    }

    /// Subject filter and sort order, as a standard toolbar menu.
    private var filterMenu: some View {
        Menu {
            Picker("Fach", selection: $subjectFilter) {
                Text("Alle Fächer").tag(String?.none)
                ForEach(subjects, id: \.self) { subject in
                    Text(subject).tag(String?.some(subject))
                }
            }
            Divider()
            Picker("Sortierung", selection: $newestFirst) {
                Text("Neueste zuerst").tag(true)
                Text("Älteste zuerst").tag(false)
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
        loading = lessons.isEmpty
        errorMessage = nil
        do {
            lessons = try await api.listLessons().filter { $0.segmentCount > 0 }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
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

/// One day as a folder row: date, lesson count badge, and the subjects.
struct DayRow: View {
    let day: Date
    let lessons: [BackendAPI.LessonInfo]

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "folder.fill", color: .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .badge(lessons.count)
    }

    private var subtitle: String {
        let names = lessons.compactMap { $0.subject ?? $0.title }
        guard !names.isEmpty else {
            return lessons.count == 1 ? "1 Stunde" : "\(lessons.count) Stunden"
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }
}

/// One school day: the day's lessons as a list with standard swipe-to-delete.
struct DayView: View {
    let api: BackendAPI
    let day: Date
    let onChanged: () async -> Void

    @State private var lessons: [BackendAPI.LessonInfo]
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        api: BackendAPI,
        day: Date,
        lessons: [BackendAPI.LessonInfo],
        onChanged: @escaping () async -> Void
    ) {
        self.api = api
        self.day = day
        self.onChanged = onChanged
        _lessons = State(initialValue: lessons)
    }

    var body: some View {
        List {
            ForEach(lessons) { lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    LessonRow(info: lesson)
                }
            }
            .onDelete { offsets in
                let targets = offsets.map { lessons[$0] }
                Task {
                    for lesson in targets {
                        await delete(lesson)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(day.formatted(date: .complete, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
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

    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            withAnimation(.snappy) {
                lessons.removeAll { $0.id == lesson.id }
            }
            await onChanged()
            // the day folder no longer exists in the archive: leave it
            if lessons.isEmpty { dismiss() }
        } catch {
            actionError = error.localizedDescription
        }
    }
}
