import SwiftUI

/// "Stunden": archive of every recording (they live on the Fedora server).
/// One screen for everything about a lesson — the detail combines the
/// Zusammenfassung and the Transkript as two segments.
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
            ErrorState(message: errorMessage) { await load() }
        } else if lessons.isEmpty {
            EmptyState(
                icon: "books.vertical",
                text: "Noch keine aufgenommenen Stunden.\nNimm eine Stunde auf, dann erscheint sie hier."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    filterBar
                    ForEach(visibleLessons) { lesson in
                        NavigationLink {
                            LessonDetailView(api: api, info: lesson)
                        } label: {
                            LessonRow(info: lesson)
                        }
                        .buttonStyle(.plain)
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

// MARK: - Detail (Zusammenfassung + Transkript in one screen)

struct LessonDetailView: View {
    enum Tab: String, CaseIterable {
        case zusammenfassung = "Zusammenfassung"
        case transkript = "Transkript"
    }

    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @State private var tab: Tab = .zusammenfassung
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
                ErrorState(message: errorMessage, retry: nil)
            } else {
                ProgressView("Lade Stunde…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground())
        .navigationTitle(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let detail {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: lessonShareText(summary: summary, segments: detail.segments)) {
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
        VStack(spacing: 14) {
            header
            Picker("Ansicht", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch tab {
            case .zusammenfassung:
                summaryTab
            case .transkript:
                transcriptTab(detail)
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: subjectSymbol(for: info.subject))
                .font(.system(size: 19))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? "Aufnahme")
                    .font(.headline)
                Text(headerMeta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(cornerRadius: 14)
    }

    private var headerMeta: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        var parts = [
            start.formatted(date: .long, time: .omitted),
            "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))",
        ]
        if let teacher = info.teacher, !teacher.isEmpty { parts.append(teacher) }
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Zusammenfassung

    @ViewBuilder
    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary {
                    Text(renderedMarkdown(summary))
                        .font(.callout)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "text.badge.star")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.accent.opacity(0.6))
                        Text("Für diese Stunde gibt es noch keine Zusammenfassung.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await generateSummary() }
                        } label: {
                            HStack(spacing: 8) {
                                if summarizing { ProgressView().tint(.white) }
                                Text(summarizing ? "Wird erstellt…" : "Zusammenfassung erstellen")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(summarizing)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
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

    // MARK: Transkript

    private func transcriptTab(_ detail: BackendAPI.LessonDetail) -> some View {
        let activeIndex = audioPlayer.activeSegmentIndex(in: detail.segments)
        return VStack(spacing: 12) {
            if info.hasAudio {
                LessonAudioBar(player: audioPlayer, api: api, lessonId: info.id)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if info.hasAudio {
                        Text("Zeile antippen, um sie anzuhören")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(detail.segments.enumerated()), id: \.element.id) { index, segment in
                        SegmentRow(segment: segment, isPartial: false)
                            .padding(.vertical, 5)
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
                .padding(14)
            }
            .paperCard()
        }
    }
}
