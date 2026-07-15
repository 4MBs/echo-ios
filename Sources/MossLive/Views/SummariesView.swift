import SwiftUI

/// "Zusammenfassungen": every lesson with its summary status; opening one
/// shows (or generates) the study summary — mockup screen 4, without the quiz.
struct SummariesView: View {
    @Environment(AppModel.self) private var model

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
                .navigationTitle("Zusammenfassungen")
                .background(PaperBackground())
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Lade Stunden…")
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Erneut versuchen") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(28)
        } else if lessons.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 34))
                    .foregroundStyle(.quaternary)
                Text("Noch keine Stunden — nach der ersten Aufnahme erscheinen sie hier.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            List(lessons) { lesson in
                NavigationLink {
                    SummaryDetailView(api: api, info: lesson)
                } label: {
                    row(lesson)
                }
                .listRowBackground(
                    Color.clear.overlay(
                        Theme.card,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .padding(.vertical, 4)
                )
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
    }

    private func row(_ info: BackendAPI.LessonInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: subjectSymbol(for: info.subject))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Text(
                    info.hasSummary
                        ? "Zusammenfassung vorhanden"
                        : "Noch keine Zusammenfassung — antippen zum Erstellen"
                )
                .font(.caption)
                .foregroundStyle(info.hasSummary ? Theme.accent : .secondary)
            }
            Spacer()
            if info.hasSummary {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 6)
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

/// One lesson's summary on a paper card, with Teilen/Exportieren in the
/// toolbar. Generates the summary on demand (cached server-side afterwards).
struct SummaryDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @State private var detail: BackendAPI.LessonDetail?
    @State private var summary: String?
    @State private var summarizing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                if let summary {
                    summaryCard(summary)
                } else if detail != nil {
                    generateButton
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Lade Stunde…")
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
                if let errorMessage, detail != nil {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground())
        .navigationTitle("Zusammenfassung")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: summary) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                }
                if let detail {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: lessonShareText(summary: summary, segments: detail.segments)) {
                            Label("Exportieren", systemImage: "arrow.down.doc")
                        }
                    }
                }
            }
        }
        .task {
            do {
                let loaded = try await api.lesson(id: info.id)
                detail = loaded
                summary = loaded.summary
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title ?? info.startedAt.formatted(date: .long, time: .omitted))
                .font(.title3.weight(.bold))
            Text(timeRange)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var timeRange: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        let day = start.formatted(date: .abbreviated, time: .omitted)
        let from = start.formatted(date: .omitted, time: .shortened)
        let to = end.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(from) – \(to)"
    }

    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Zusammenfassung", systemImage: "text.badge.star")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(renderedMarkdown(text))
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            HStack(spacing: 8) {
                if summarizing {
                    ProgressView()
                } else {
                    Image(systemName: "text.badge.star")
                }
                Text(summarizing ? "Fasse die Stunde zusammen…" : "Zusammenfassung erstellen")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(Theme.accent)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(summarizing)
    }

    private func generate() async {
        summarizing = true
        errorMessage = nil
        do {
            summary = try await api.summarize(id: info.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        summarizing = false
    }
}
