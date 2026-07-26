import SwiftUI

/// One lesson, as a document rather than a form.
///
/// Zusammenfassung and Transkript are two pages of the same thing, so the
/// switch between them sits under the title where it stays put, and the
/// recording plays along either of them — audio belongs to the lesson, not to
/// one of its pages. Both pages are text on a page: the transcript used to be
/// rendered as grouped list rows, which turned a spoken hour into a table.
struct LessonDetailView: View {
    enum Page: String, CaseIterable, Identifiable {
        case zusammenfassung = "Zusammenfassung"
        case transkript = "Transkript"

        var id: String { rawValue }
    }

    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model
    @State private var loadError: Error?
    @State private var page: Page = .zusammenfassung
    @State private var detail: BackendAPI.LessonDetail?
    @State private var summary: String?
    @State private var summarizing = false
    @State private var errorMessage: String?
    @State private var audioPlayer = LessonAudioPlayer()

    /// The readable column. Text set across the full width of an iPad is a
    /// wall; every reading app on the system stops somewhere around here.
    private static let columnWidth: CGFloat = 700

    var body: some View {
        Group {
            if let detail {
                document(detail)
            } else if let loadError {
                ErrorState(loadError)
            } else {
                ProgressView("Lade Stunde…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        // The lesson names the screen. It used to be replaced by the page
        // switch, which left the title to a row further down the page.
        .navigationTitle(info.title ?? info.subject ?? "Aufnahme")
        .navigationSubtitle(metaLine)
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
        .task { await load() }
    }

    /// The stored copy first, so a lesson opens instantly and opens at all
    /// without a server; the server's copy replaces it when there is one.
    private func load() async {
        let key = OfflineCache.Key.lesson(info.id)
        if let stored = OfflineCache.load(BackendAPI.LessonDetail.self, key: key) {
            detail = stored
            summary = stored.summary
        }
        do {
            let loaded = try await api.lesson(id: info.id)
            detail = loaded
            summary = loaded.summary
            OfflineCache.save(loaded, as: key)
        } catch {
            if detail == nil { loadError = error }
        }
    }

    private func document(_ detail: BackendAPI.LessonDetail) -> some View {
        Group {
            switch page {
            case .zusammenfassung: summaryPage
            case .transkript: transcriptPage(detail)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { pagePicker }
        .safeAreaInset(edge: .bottom, spacing: 0) { audioBar }
    }

    /// Date, time and room, in the subtitle line the navigation bar has for
    /// exactly this. It replaces three list rows that said the same thing.
    private var metaLine: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        let range = start.formatted(date: .abbreviated, time: .omitted)
            + " · \(start.formatted(date: .omitted, time: .shortened))–"
            + end.formatted(date: .omitted, time: .shortened)
        var parts = [range]
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        if let teacher = info.teacher, !teacher.isEmpty { parts.append(teacher) }
        return parts.joined(separator: " · ")
    }

    private var pagePicker: some View {
        Picker("Ansicht", selection: $page) {
            ForEach(Page.allCases) { page in
                Text(page.rawValue).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The recording is only playable if it is already on the iPad or can
    /// still be fetched; offering a player that cannot start is worse than not
    /// offering one.
    @ViewBuilder
    private var audioBar: some View {
        if info.hasAudio, model.connectivity.isOnline || BackendAPI.cachedAudio(id: info.id) != nil {
            LessonAudioBar(player: audioPlayer, api: api, lessonId: info.id)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    // MARK: Zusammenfassung

    @ViewBuilder
    private var summaryPage: some View {
        if let summary {
            ScrollView {
                Text(renderedMarkdown(summary))
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: Self.columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
        } else if summarizing {
            ProgressView("Zusammenfassung wird erstellt…")
        } else {
            ContentUnavailableView {
                Label("Keine Zusammenfassung", systemImage: "text.badge.star")
            } description: {
                Text(model.connectivity.isOnline
                    ? "Die KI fasst das Transkript dieser Stunde zusammen."
                    : "Dafür wird der Server gebraucht.")
            } actions: {
                Button("Zusammenfassung erstellen") {
                    Task { await generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connectivity.isOnline)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func generateSummary() async {
        summarizing = true
        errorMessage = nil
        do {
            let text = try await api.summarize(id: info.id)
            summary = text
            // Keep the stored copy current, or the summary would vanish the
            // next time the lesson is opened without a server.
            if var stored = detail {
                stored.summary = text
                detail = stored
                OfflineCache.save(stored, as: OfflineCache.Key.lesson(info.id))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        summarizing = false
    }

    // MARK: Transkript

    @ViewBuilder
    private func transcriptPage(_ detail: BackendAPI.LessonDetail) -> some View {
        if detail.segments.isEmpty {
            ContentUnavailableView {
                Label("Kein Transkript", systemImage: "text.alignleft")
            } description: {
                Text("In dieser Aufnahme wurde nichts erkannt.")
            }
        } else {
            let active = audioPlayer.activeSegmentIndex(in: detail.segments)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(detail.segments.enumerated()), id: \.element.id) { index, segment in
                            line(segment, isActive: index == active)
                                .id(segment.id)
                        }
                    }
                    .frame(maxWidth: Self.columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                // Playback carries the page along with it, the way a transcript
                // that can be played is expected to behave.
                .onChange(of: active) { _, index in
                    guard let index, detail.segments.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(detail.segments[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    /// A line is only a control where there is something to play.
    @ViewBuilder
    private func line(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        if info.hasAudio {
            Button {
                Task {
                    if await audioPlayer.ensureLoaded(api: api, lessonId: info.id) {
                        audioPlayer.playFrom(segment.t0)
                    }
                }
            } label: {
                SegmentRow(segment: segment, isPartial: false, isActive: isActive)
            }
            .buttonStyle(.plain)
        } else {
            SegmentRow(segment: segment, isPartial: false, isActive: isActive)
        }
    }
}
