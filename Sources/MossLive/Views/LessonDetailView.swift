import SwiftUI

/// One lesson, as three cards on the grouped canvas: what it was about, the
/// recording, and what was said.
///
/// The parts of a lesson are different kinds of thing — a paragraph you read, a
/// control you operate, a document you scan — and putting them in one list made
/// them all look like settings rows. Each gets its own card, on the same canvas
/// the subject folders sit on, so the tab holds together.
///
/// There is no switch between Zusammenfassung and Transkript: they are the top
/// and the bottom of one page, and a switch that rebuilt hundreds of transcript
/// lines on every tap was the slowest thing on the screen. The summary is
/// parsed from Markdown once when it arrives, and the spoken line comes from
/// `player.activeIndex`, which changes when the line changes rather than seven
/// times a second.
struct LessonDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model

    @State private var detail: BackendAPI.LessonDetail?
    /// Parsed once. The raw text is kept beside it for sharing, which wants
    /// characters rather than attributes.
    @State private var summary: AttributedString?
    @State private var summaryText: String?
    @State private var peaks: [Double] = []
    @State private var loadError: Error?
    @State private var summarizing = false
    @State private var errorMessage: String?
    @State private var player = LessonAudioPlayer()

    /// The readable column. Text set across the full width of an iPad is a
    /// wall; every reading app on the system stops somewhere around here.
    private static let column: CGFloat = 700

    var body: some View {
        Group {
            if let detail {
                page(detail)
            } else if let loadError {
                ErrorState(loadError) { await load() }
                    .groupedScreen()
            } else {
                ProgressView("Lade Stunde…")
                    .groupedScreen()
            }
        }
        .navigationTitle(info.subject ?? info.title ?? "Aufnahme")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let detail {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: lessonShareText(summary: summaryText, segments: detail.segments)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onDisappear { player.stop() }
        .task { await load() }
    }

    // MARK: - The page

    private func page(_ detail: BackendAPI.LessonDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    summaryCard
                    if info.hasAudio { playerCard }
                    if !detail.segments.isEmpty { transcriptCard(detail) }
                }
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .groupedScreen()
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

    /// When it was, where, and with whom — as chips rather than three list rows
    /// saying one fact each.
    private var facts: some View {
        HStack(spacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var chips: [String] {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        var out = [
            start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                + ", " + start.formatted(date: .omitted, time: .shortened)
                + "–" + end.formatted(date: .omitted, time: .shortened),
        ]
        if let room = info.room, !room.isEmpty { out.append("Raum \(room)") }
        if let teacher = info.teacher, !teacher.isEmpty { out.append(teacher) }
        return out
    }

    // MARK: - Cards

    private func cardHeader(_ title: String, systemImage: String, trailing: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("Zusammenfassung", systemImage: "sparkles")
            if let summary {
                Text(summary)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if summarizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Wird geschrieben…").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 2)
            } else {
                summaryPrompt
            }
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

    /// The server writes summaries by itself when a recording ends, so an
    /// absent one means it was skipped or it failed — not that nobody has
    /// pressed the button yet.
    private var summaryPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.connectivity.isOnline
                ? "Für diese Stunde wurde keine geschrieben."
                : "Für diese Stunde wurde keine geschrieben. Dafür wird der Server gebraucht.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Jetzt erstellen") {
                Task { await generateSummary() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(summarizing || !model.connectivity.isOnline)
        }
    }

    private var playerCard: some View {
        LessonPlayer(player: player, api: api, lessonId: info.id, peaks: peaks)
            .padding(14)
            .frame(maxWidth: .infinity)
            .cardSurface()
    }

    private func transcriptCard(_ detail: BackendAPI.LessonDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                "Transkript",
                systemImage: "text.alignleft",
                trailing: "\(detail.segments.count) Zeilen"
            )
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
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive ? Theme.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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
        if peaks.isEmpty,
           let stored = OfflineCache.load([Double].self, key: OfflineCache.Key.waveform(info.id)) {
            peaks = stored
        }
        do {
            let loaded = try await api.lesson(id: info.id)
            apply(loaded)
            OfflineCache.save(loaded, as: key)
        } catch {
            if detail == nil { loadError = error }
        }
        await loadWaveform()
    }

    /// The waveform is decoration on a control that works without it, so a
    /// server too old to know the endpoint just gets a plain track.
    private func loadWaveform() async {
        guard info.hasAudio, peaks.isEmpty else { return }
        guard let fresh = try? await api.waveform(id: info.id), !fresh.isEmpty else { return }
        peaks = fresh
        OfflineCache.save(fresh, as: OfflineCache.Key.waveform(info.id))
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
