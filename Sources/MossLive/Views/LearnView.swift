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
                .paperScreen()
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
                .onAppear { Task { await load() } }
        } else if let errorMessage {
            ErrorState(message: errorMessage) { await load() }
        } else if let overview {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    todayCard(overview)
                    if !overview.subjects.isEmpty {
                        sectionTitle("Fächer")
                        ForEach(overview.subjects) { subject in
                            SubjectRow(api: api, subject: subject)
                        }
                    }
                    if !pendingLessons.isEmpty {
                        sectionTitle("Noch nicht abgefragt")
                        Text("Beim ersten Abfragen entsteht der Kartensatz der Stunde.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        ForEach(pendingLessons) { lesson in
                            pendingRow(lesson)
                        }
                    }
                    if overview.cardTotal == 0, pendingLessons.isEmpty {
                        EmptyState(
                            icon: "brain.head.profile",
                            text: "Noch nichts zu lernen.\nNimm eine Stunde auf, dann erscheinen hier ihre Karten."
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
            .onAppear { Task { await load() } }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 10)
    }

    // MARK: - Heute lernen

    @ViewBuilder
    private func todayCard(_ overview: BackendAPI.LearnOverview) -> some View {
        if overview.dueTotal > 0 {
            NavigationLink {
                ReviewView(api: api, title: "Heute lernen", mode: .review) {
                    try await api.dueCards()
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 19))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Heute lernen")
                            .font(.body.weight(.semibold))
                        Text(overview.dueTotal == 1
                            ? "1 Karte ist fällig"
                            : "\(overview.dueTotal) Karten sind fällig")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
            .buttonStyle(.plain)
        } else if overview.cardTotal > 0 {
            HStack(spacing: 22) {
                Text("Für heute alles gelernt!")
                    .stickyNote(rotation: -1)
                Doodle(name: "doodle-trophy", size: 56, rotation: 7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
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
            HStack(spacing: 14) {
                Image(systemName: subjectSymbol(for: lesson.subject))
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(lesson.title ?? "Aufnahme")
                        .font(.subheadline.weight(.semibold))
                    Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
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
    }
}

/// One subject's deck: tap reviews what's due; "Üben" runs the whole deck
/// without touching the schedule.
private struct SubjectRow: View {
    let api: BackendAPI
    let subject: BackendAPI.LearnSubject

    private var name: String { subject.subject ?? "Ohne Fach" }

    var body: some View {
        HStack(spacing: 14) {
            NavigationLink {
                ReviewView(api: api, title: name, mode: .review) {
                    try await api.dueCards(subject: subject.subject)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: subjectSymbol(for: subject.subject))
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(subject.due == 0)

            NavigationLink {
                ReviewView(api: api, title: "\(name) üben", mode: .practice) {
                    try await api.allCards(subject: subject.subject)
                }
            } label: {
                Text("Üben")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(cornerRadius: 14)
    }

    private var subtitle: String {
        let total = subject.total == 1 ? "1 Karte" : "\(subject.total) Karten"
        return subject.due == 0 ? "Nichts fällig · \(total)" : "\(subject.due) fällig · \(total)"
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
