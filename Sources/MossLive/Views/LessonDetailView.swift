import SwiftUI

/// One lesson as a single document: what it was about, then what was said.
///
/// There is no switch between Zusammenfassung and Transkript, because there is
/// nothing to switch — they are the top and the bottom of the same page, and a
/// switch that rebuilt hundreds of transcript lines on every tap was the
/// slowest thing on the screen.
///
/// The rest of the old lag was in what the page recomputed while it simply sat
/// there. The summary was re-parsed from Markdown on every redraw, and every
/// redraw was driven by the audio player's clock, which ticks seven times a
/// second. The summary is now parsed once, when it arrives, and the spoken line
/// comes from `player.activeIndex`, which changes when the line changes.
struct LessonDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model

    @State private var detail: BackendAPI.LessonDetail?
    /// Parsed once. The raw text is kept beside it for sharing, which wants
    /// characters rather than attributes.
    @State private var summary: AttributedString?
    @State private var summaryText: String?
    @State private var loadError: Error?
    @State private var summarizing = false
    @State private var errorMessage: String?
    @State private var player = LessonAudioPlayer()

    /// The readable column. Text set across the full width of an iPad is a
    /// wall; every reading app on the system stops somewhere around here.
    private static let column: CGFloat = 680

    private enum Anchor: Hashable {
        case transcript
    }

    var body: some View {
        Group {
            if let detail {
                document(detail)
            } else if let loadError {
                ErrorState(loadError) { await load() }
            } else {
                ProgressView("Lade Stunde…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(info.subject ?? info.title ?? "Aufnahme")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .task { await load() }
    }

    // MARK: - The page

    private func document(_ detail: BackendAPI.LessonDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    summaryBlock
                    if !detail.segments.isEmpty {
                        transcriptBlock(detail)
                    }
                }
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 44)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { audioBar }
            .toolbar {
                // Inside the reader, so the button can reach the proxy. Going
                // back up is the scroll view's own job (a tap on the status
                // bar), so there is only one direction worth offering.
                if !detail.segments.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(Anchor.transcript, anchor: .top)
                            }
                        } label: {
                            Label("Zum Transkript", systemImage: "text.alignleft")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: lessonShareText(summary: summaryText, segments: detail.segments)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            // Playback carries the page with it, the way a transcript that can
            // be played is expected to behave.
            .onChange(of: player.activeIndex) { _, index in
                guard player.isPlaying, let index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let style = subjectStyle(for: info.subject)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: style.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(style.color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? info.subject ?? "Aufnahme")
                    .font(.title2.weight(.semibold))
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Date, time, room and teacher on one line, where three list rows used to
    /// say the same thing one fact at a time.
    private var metaLine: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        var parts = [
            start.formatted(date: .abbreviated, time: .omitted)
                + " · \(start.formatted(date: .omitted, time: .shortened))–"
                + end.formatted(date: .omitted, time: .shortened),
        ]
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        if let teacher = info.teacher, !teacher.isEmpty { parts.append(teacher) }
        return parts.joined(separator: " · ")
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The recording is only playable if it is already on the iPad or can
    /// still be fetched; offering a player that cannot start is worse than not
    /// offering one.
    @ViewBuilder
    private var audioBar: some View {
        if info.hasAudio, model.connectivity.isOnline || BackendAPI.cachedAudio(id: info.id) != nil {
            LessonAudioBar(player: player, api: api, lessonId: info.id)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    // MARK: - Zusammenfassung

    @ViewBuilder
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Zusammenfassung")
            if let summary {
                Text(summary)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if summarizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Wird geschrieben…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                summaryPrompt
            }
        }
    }

    private var summaryPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.connectivity.isOnline
                ? "Noch keine. Die KI schreibt sie aus dem Transkript dieser Stunde."
                : "Noch keine. Dafür wird der Server gebraucht.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Zusammenfassung erstellen") {
                Task { await generateSummary() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(summarizing || !model.connectivity.isOnline)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Transkript

    private func transcriptBlock(_ detail: BackendAPI.LessonDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Transkript")
                .id(Anchor.transcript)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(detail.segments.indices, id: \.self) { index in
                    line(detail.segments[index], isActive: player.activeIndex == index)
                        .id(index)
                }
            }
            if info.hasAudio {
                Text("Zeile antippen, um sie ab dieser Stelle anzuhören.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    /// A line is only a control where there is something to play.
    @ViewBuilder
    private func line(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        if info.hasAudio {
            Button {
                Task {
                    if await player.ensureLoaded(api: api, lessonId: info.id) {
                        player.playFrom(segment.t0)
                    }
                }
            } label: {
                lineBody(segment, isActive: isActive)
            }
            .buttonStyle(.plain)
        } else {
            lineBody(segment, isActive: isActive)
        }
    }

    private func lineBody(_ segment: TranscriptSegment, isActive: Bool) -> some View {
        SegmentRow(segment: segment, isPartial: false, isActive: isActive)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive ? Theme.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    // MARK: - Loading

    /// The stored copy first, so a lesson opens instantly and opens at all
    /// without a server; the server's copy replaces it when there is one.
    private func load() async {
        let key = OfflineCache.Key.lesson(info.id)
        if let stored = OfflineCache.load(BackendAPI.LessonDetail.self, key: key) {
            apply(stored)
        }
        do {
            let loaded = try await api.lesson(id: info.id)
            apply(loaded)
            OfflineCache.save(loaded, as: key)
        } catch {
            if detail == nil { loadError = error }
        }
    }

    /// Everything the page derives from a loaded lesson, worked out once here
    /// rather than on every redraw: the Markdown parse, and the transcript the
    /// player highlights against.
    private func apply(_ loaded: BackendAPI.LessonDetail) {
        detail = loaded
        setSummary(loaded.summary)
        player.track(loaded.segments)
    }

    private func setSummary(_ text: String?) {
        summaryText = text
        summary = text.map(renderedMarkdown)
    }

    private func generateSummary() async {
        summarizing = true
        errorMessage = nil
        do {
            let text = try await api.summarize(id: info.id)
            setSummary(text)
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
}
