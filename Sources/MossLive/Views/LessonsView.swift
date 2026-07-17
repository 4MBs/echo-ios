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
                .paperScreen()
                .navigationTitle("Meine Stunden")
                .searchable(text: $searchText, prompt: "Suchen")
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
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }
        } else if lessons.isEmpty {
            EmptyState(
                icon: "books.vertical",
                text: "Noch keine aufgenommenen Stunden.\nNimm eine Stunde auf, dann erscheint sie hier."
            )
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        filterBar
                        ForEach(days, id: \.day) { entry in
                            NavigationLink {
                                DayView(api: api, day: entry.day, lessons: entry.lessons) {
                                    await load()
                                }
                            } label: {
                                DayRow(day: entry.day, lessons: entry.lessons)
                            }
                            .buttonStyle(PaperPressStyle())
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
                MarginDoodles()
            }
        }
    }

    /// Filter chips: subject and sort order.
    private var filterBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Alle Fächer") { subjectFilter = nil }
                ForEach(subjects, id: \.self) { subject in
                    Button(subject) { subjectFilter = subject }
                }
            } label: {
                chipLabel(subjectFilter ?? "Alle Fächer", highlighted: subjectFilter != nil)
            }
            Menu {
                Button("Neueste zuerst") { newestFirst = true }
                Button("Älteste zuerst") { newestFirst = false }
            } label: {
                chipLabel(newestFirst ? "Neueste zuerst" : "Älteste zuerst", highlighted: false)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func chipLabel(_ text: String, highlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Text(text)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(highlighted ? Color.white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(highlighted ? Theme.accent : Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
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
}

/// One day as a folder card: date, lesson count, and the subjects inside.
struct DayRow: View {
    let day: Date
    let lessons: [BackendAPI.LessonInfo]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 19))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(cornerRadius: 14)
    }

    private var subtitle: String {
        let count = lessons.count == 1 ? "1 Stunde" : "\(lessons.count) Stunden"
        let names = lessons.compactMap { $0.subject ?? $0.title }
        guard !names.isEmpty else { return count }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return "\(count) · \(unique.joined(separator: ", "))"
    }
}

/// One school day: the day's lessons, one card each.
struct DayView: View {
    let api: BackendAPI
    let day: Date
    let onChanged: () async -> Void

    @State private var lessons: [BackendAPI.LessonInfo]
    @State private var actionError: String?

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
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(lessons) { lesson in
                    NavigationLink {
                        LessonDetailView(api: api, info: lesson)
                    } label: {
                        LessonRow(info: lesson)
                    }
                    .buttonStyle(PaperPressStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await delete(lesson) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
        .paperScreen()
        .navigationTitle(day.formatted(date: .complete, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
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
        } catch {
            actionError = error.localizedDescription
        }
    }
}
