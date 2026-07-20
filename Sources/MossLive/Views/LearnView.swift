import SwiftUI
import UserNotifications

/// "Lernen": the spaced-repetition home. One tap reviews everything due
/// today; below that, per-subject decks and lessons whose deck hasn't been
/// generated yet. The schedule lives on the server (Leitner ladder).
struct LearnView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: BackendAPI.LearnOverview?
    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var errorMessage: String?

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
                .navigationTitle("Lernen")
        }
    }

    /// Lessons that don't have a card deck yet, newest first.
    private var pendingLessons: [BackendAPI.LessonInfo] {
        let withCards = Set(overview?.sessionsWithCards ?? [])
        return lessons
            .filter { $0.segmentCount > 0 && !withCards.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private var content: some View {
        if loading, overview == nil {
            ProgressView("Lade Lernstand…")
                .groupedScreen()
                .onAppear { Task { await load() } }
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }
                .groupedScreen()
        } else if let overview {
            if overview.cardTotal == 0, pendingLessons.isEmpty {
                ContentUnavailableView {
                    Label("Noch nichts zu lernen", systemImage: "brain.head.profile")
                } description: {
                    Text("Nimm eine Stunde auf, dann erscheinen hier ihre Karten.")
                }
                .groupedScreen()
                .onAppear { Task { await load() } }
            } else {
                List {
                    todaySection(overview)
                    if !overview.subjects.isEmpty {
                        Section("Fächer") {
                            ForEach(overview.subjects) { subject in
                                SubjectRow(api: api, subject: subject)
                            }
                        }
                    }
                    if !pendingLessons.isEmpty {
                        Section {
                            ForEach(pendingLessons) { lesson in
                                pendingRow(lesson)
                            }
                        } header: {
                            Text("Noch nicht abgefragt")
                        } footer: {
                            Text("Beim ersten Abfragen entsteht der Kartensatz der Stunde.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
                .onAppear { Task { await load() } }
            }
        }
    }

    // MARK: - Heute lernen

    @ViewBuilder
    private func todaySection(_ overview: BackendAPI.LearnOverview) -> some View {
        if overview.dueTotal > 0 {
            Section {
                NavigationLink {
                    ReviewView(api: api, title: "Heute lernen", mode: .review) {
                        try await api.dueCards()
                    }
                } label: {
                    HStack(spacing: 12) {
                        IconTile(systemName: "sparkles", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Heute lernen")
                                .font(.body.weight(.semibold))
                            Text(overview.dueTotal == 1
                                ? "1 Karte ist fällig"
                                : "\(overview.dueTotal) Karten sind fällig")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else if overview.cardTotal > 0 {
            Section {
                Label {
                    Text("Für heute alles gelernt!")
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Noch nicht abgefragt

    private func pendingRow(_ lesson: BackendAPI.LessonInfo) -> some View {
        NavigationLink {
            ReviewView(
                api: api,
                title: lesson.title ?? "Stunde abfragen",
                mode: .review
            ) {
                try await api.generateCards(sessionId: lesson.id)
            }
        } label: {
            let style = subjectStyle(for: lesson.subject)
            HStack(spacing: 12) {
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title ?? "Aufnahme")
                    Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 2)
        }
    }

    private func load() async {
        guard !refreshing else { return }
        refreshing = true
        // Show the spinner (not a blank page) while the first load or an
        // error retry runs; later loads refresh silently behind the content.
        if overview == nil { loading = true }
        errorMessage = nil
        do {
            async let ov = api.learnOverview()
            async let ls = api.listLessons()
            overview = try await ov
            lessons = try await ls
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
        refreshing = false
    }
}

/// One subject's deck: tap reviews what's due (or practices the whole deck
/// when nothing is due); "Üben" via swipe or long-press never touches the
/// schedule.
private struct SubjectRow: View {
    let api: BackendAPI
    let subject: BackendAPI.LearnSubject

    private var name: String { subject.subject ?? "Ohne Fach" }

    @State private var practicing = false

    var body: some View {
        NavigationLink {
            if subject.due > 0 {
                ReviewView(api: api, title: name, mode: .review) {
                    try await api.dueCards(subject: subject.subject)
                }
            } else {
                practiceDestination
            }
        } label: {
            let style = subjectStyle(for: subject.subject)
            HStack(spacing: 12) {
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .badge(subject.due)
        }
        .swipeActions(edge: .trailing) { practiceButton.tint(Theme.accent) }
        .contextMenu { practiceButton }
        .navigationDestination(isPresented: $practicing) { practiceDestination }
    }

    private var practiceButton: some View {
        Button {
            practicing = true
        } label: {
            Label("Üben", systemImage: "arrow.clockwise")
        }
    }

    private var practiceDestination: some View {
        ReviewView(api: api, title: "\(name) üben", mode: .practice) {
            try await api.allCards(subject: subject.subject)
        }
    }

    private var subtitle: String {
        let total = subject.total == 1 ? "1 Karte" : "\(subject.total) Karten"
        return subject.due == 0 ? "\(total) · Nichts fällig, tippen zum Üben" : total
    }
}

/// Daily "time to review" local notification (repeats every day at the
/// configured time; the system keeps it across launches).
enum LearnReminder {
    static func sync(enabled: Bool, minuteOfDay: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["learn-reminder"])
        guard enabled else { return }
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zeit zum Lernen"
        content.body = "Schau nach, welche Karten heute fällig sind."
        content.sound = .default
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let request = UNNotificationRequest(
            identifier: "learn-reminder",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        try? await center.add(request)
    }
}
