import SwiftUI

/// "Meine Stunden": every past recording lives on the Fedora server; this
/// screen lists them (filterable by subject), shows the full transcript and
/// the per-lesson summary.
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var subjectFilter: String?
    @State private var newestFirst = true

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
                .navigationTitle("Meine Stunden")
                .background(PaperBackground())
        }
        .task { await load() }
    }

    private var subjects: [String] {
        Array(Set(lessons.compactMap(\.subject))).sorted()
    }

    private var visibleLessons: [BackendAPI.LessonInfo] {
        var result = lessons
        if let subjectFilter {
            result = result.filter { $0.subject == subjectFilter }
        }
        return newestFirst ? result : result.reversed()
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
                Image(systemName: "books.vertical")
                    .font(.system(size: 34))
                    .foregroundStyle(.quaternary)
                Text("Noch keine aufgenommenen Stunden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            List {
                Section {
                    ForEach(visibleLessons) { lesson in
                        NavigationLink {
                            LessonDetailView(api: api, info: lesson)
                        } label: {
                            LessonRow(info: lesson)
                        }
                        .listRowBackground(
                            Color.clear.overlay(
                                Theme.card,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .padding(.vertical, 4)
                        )
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await delete(lesson) }
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    filterBar
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
            .alert(
                "Stunde konnte nicht gelöscht werden",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    /// Mockup-style filter chips: subject and sort order.
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
        .padding(.vertical, 8)
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

    private func delete(_ lesson: BackendAPI.LessonInfo) async {
        do {
            try await api.deleteLesson(id: lesson.id)
            BackendAPI.purgeCachedAudio(id: lesson.id)
            lessons.removeAll { $0.id == lesson.id }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct LessonRow: View {
    let info: BackendAPI.LessonInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: subjectSymbol(for: info.subject))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if info.hasSummary {
                Image(systemName: "text.badge.star")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 6)
    }

    private var durationLabel: String {
        let minutes = Int(info.durationSeconds) / 60
        let seconds = Int(info.durationSeconds) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
    }

    /// When the lesson is titled from the timetable, the date/room become the
    /// secondary line; otherwise fall back to duration + segment count.
    private var secondaryLine: String {
        if info.title != nil {
            var parts = [info.startedAt.formatted(date: .abbreviated, time: .shortened), durationLabel]
            if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
            return parts.joined(separator: " · ")
        }
        return "\(durationLabel) · \(info.segmentCount) Abschnitte"
    }
}

// MARK: - Detail

struct LessonDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @State private var detail: BackendAPI.LessonDetail?
    @State private var summary: String?
    @State private var summarizing = false
    @State private var errorMessage: String?
    @State private var audioPlayer = LessonAudioPlayer()

    var body: some View {
        Group {
            if let detail {
                loadedContent(detail)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ProgressView("Lade Transkript…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground())
        .navigationTitle(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let detail {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(detail)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onDisappear { audioPlayer.stop() }
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

    private func loadedContent(_ detail: BackendAPI.LessonDetail) -> some View {
        let multiSpeaker = Set(detail.segments.map(\.speaker)).count > 1
        let activeIndex = audioPlayer.activeSegmentIndex(in: detail.segments)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summarySection
                if info.hasAudio {
                    LessonAudioBar(player: audioPlayer, api: api, lessonId: info.id)
                }
                Text(info.hasAudio ? "Transkript · Zeile antippen zum Anhören" : "Transkript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(detail.segments.enumerated()), id: \.element.id) { index, segment in
                        SegmentRow(
                            segment: segment,
                            isPartial: false,
                            speakerStyle: !multiSpeaker
                                ? .hidden
                                : (index == 0 || detail.segments[index - 1].speaker != segment.speaker)
                                ? .shown
                                : .placeholder
                        )
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            index == activeIndex ? Theme.accent.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard info.hasAudio else { return }
                            Task {
                                if await audioPlayer.ensureLoaded(api: api, lessonId: info.id) {
                                    audioPlayer.playFrom(segment.t0)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .paperCard()
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 8) {
                Label("Zusammenfassung", systemImage: "text.badge.star")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(renderedMarkdown(summary))
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1)
            )
        } else {
            Button {
                Task { await generateSummary() }
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
        if let errorMessage, detail != nil {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func generateSummary() async {
        summarizing = true
        errorMessage = nil
        do {
            summary = try await api.summarize(id: info.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        summarizing = false
    }

    private func shareText(_ detail: BackendAPI.LessonDetail) -> String {
        lessonShareText(summary: summary, segments: detail.segments)
    }
}
