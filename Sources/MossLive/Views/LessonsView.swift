import SwiftUI

/// "Stunden": the school week, drawn to scale, with the recordings sitting in
/// the lessons they were made in.
///
/// The archive used to be a list of what had been recorded, which meant the
/// one question it could not answer was the obvious one — was this lesson
/// recorded at all? A timetable answers it by shape: a filled block was
/// captured, an outlined one was not. Searching is the way back to a single
/// recording when the week it happened in is not the point.
struct LessonsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var store = StundenStore()
    @State private var monday = SchoolClock.monday(of: .now, calendar: .current)
    @State private var day = 0
    @State private var searchText = ""
    @State private var actionError: String?

    private var api: BackendAPI { model.api }
    private var calendar: Calendar { Calendar.current }
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var isCompact: Bool { sizeClass == .compact }
    private var thisWeek: Date { SchoolClock.monday(of: .now, calendar: calendar) }

    var body: some View {
        NavigationStack {
            Group {
                if store.hasRecordings {
                    week.searchable(text: $searchText, prompt: "Aufnahme suchen")
                } else {
                    week
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert(
                "Löschen fehlgeschlagen",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
        .task {
            await store.loadRecordings(api: api)
        }
        // Weeks are fetched as they are looked at, and kept.
        .task(id: monday) {
            await store.loadWeek(monday, api: api)
        }
    }

    private var title: String {
        "KW \(calendar.component(.weekOfYear, from: monday))"
    }

    @ViewBuilder
    private var week: some View {
        if !query.isEmpty {
            searchResults
        } else if let layout = store.layout(for: monday) {
            grid(layout)
        } else if store.isLoading(monday) {
            ProgressView("Lade Woche…")
                .groupedScreen()
        } else {
            ContentUnavailableView {
                Label("Keine Woche", systemImage: "calendar")
            } description: {
                Text("Der Stundenplan konnte nicht geladen werden.")
            }
            .groupedScreen()
        }
    }

    @ViewBuilder
    private func grid(_ layout: WeekLayout) -> some View {
        if let holiday = layout.wholeWeekHoliday {
            ContentUnavailableView {
                Label(holiday, systemImage: "beach.umbrella")
            } description: {
                Text("Diese Woche ist unterrichtsfrei.")
            }
            .groupedScreen()
        } else if layout.isEmpty {
            ContentUnavailableView {
                Label("Nichts in dieser Woche", systemImage: "calendar")
            } description: {
                Text(model.timetable.enabled
                    ? "Kein Unterricht und keine Aufnahmen."
                    : "Verbinde WebUntis in den Einstellungen, damit hier dein Stundenplan steht.")
            }
            .groupedScreen()
        } else {
            VStack(spacing: 0) {
                if isCompact {
                    dayPicker(layout)
                }
                WeekGridView(
                    layout: layout,
                    api: api,
                    singleDay: isCompact ? day : nil,
                    onRecord: { _ in Task { await model.startRecording() } }
                )
            }
            .background(Color(.systemBackground))
            .refreshable {
                await store.loadWeek(monday, api: api)
                await store.loadRecordings(api: api)
            }
        }
    }

    /// On a phone the five columns become one, picked here.
    private func dayPicker(_ layout: WeekLayout) -> some View {
        Picker("Tag", selection: $day) {
            ForEach(Array(layout.days.enumerated()), id: \.element.id) { index, entry in
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated))).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Search is the way to a single recording when its week is not the point.
    /// It reaches every recording, including the ones no lesson claims.
    @ViewBuilder
    private var searchResults: some View {
        let matches = store.matching(query)
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
                .groupedScreen()
        } else {
            List {
                Section {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, lesson in
                        NavigationLink {
                            LessonDetailView(api: api, info: lesson)
                        } label: {
                            LessonRow(info: lesson)
                        }
                        .listRowBackground(
                            GroupedRowBackground(isFirst: index == 0, isLast: index == matches.count - 1)
                        )
                        .swipeActions(edge: .trailing) {
                            if model.connectivity.isOnline {
                                Button(role: .destructive) {
                                    Task { actionError = await store.delete(lesson, api: api) }
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if monday != thisWeek {
                Button("Heute") { go(to: thisWeek) }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                shift(by: -1)
            } label: {
                Label("Vorherige Woche", systemImage: "chevron.left")
            }
            Button {
                shift(by: 1)
            } label: {
                Label("Nächste Woche", systemImage: "chevron.right")
            }
        }
    }

    private func shift(by weeks: Int) {
        guard let next = calendar.date(byAdding: .weekOfYear, value: weeks, to: monday) else { return }
        go(to: next)
    }

    private func go(to target: Date) {
        withAnimation(.easeInOut(duration: 0.2)) {
            monday = target
            day = min(day, 4)
        }
    }
}
