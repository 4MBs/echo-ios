import SwiftUI

/// The measurements the lesson page is built from.
///
/// The gutter is the load-bearing one. Timestamps hang in it and the thread of
/// the transcript stands on its inner edge, so the page has a single left
/// margin and that margin is made of time.
enum LessonMetrics {
    static let gutter: CGFloat = 52
    static let threadGap: CGFloat = 14
    static let textInset: CGFloat = 10
    static let measure: CGFloat = 760
    static let rail: CGFloat = 276

    /// Where the transcript's glyphs start: past the gutter, past the thread.
    static var textLeading: CGFloat { gutter + threadGap + textInset }
}

/// A position in the recording, spelled the way this screen spells it.
///
/// An offset rather than a time of day: the number under the scrubber, the
/// number beside a transcript line and the number you would say out loud to
/// find the moment again are then all the same number.
func lessonOffsetLabel(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let rest = total % 3600
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, rest / 60, rest % 60)
    }
    return String(format: "%02d:%02d", rest / 60, rest % 60)
}

/// Where playback would start.
///
/// Its own little box rather than a `@State` on the screen, because a `@State`
/// invalidates the view that owns it: dragging the scrubber would have rebuilt
/// the whole page sixty times a second to move one line. As an observed object
/// only the two views that read it — the waveform and the clock — redraw.
@MainActor
@Observable
final class LessonPlayhead {
    var time: Double = 0
}

/// One recorded lesson: what it was about, everything that was said, and the
/// recording itself.
///
/// Built on one rule: **down is later**. The transcript runs down the page, so
/// the recording runs down the rail beside it — the waveform stands on end and
/// the playhead is a cut across it. A transport bar along the bottom, which is
/// what a player usually gets, would have set time running rightwards while
/// everything it refers to ran downwards, and the two axes never meet.
///
/// The second idea is that the transcript is not prose. Nobody reads four
/// hundred lines of a classroom; the transcript is an index into the audio, so
/// every line is a place you can tap to hear it, and the summary — the part
/// that is actually read — is the page's lead text rather than a card among
/// cards.
struct LessonDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var player = LessonAudioPlayer()
    @State private var playhead = LessonPlayhead()
    @State private var detail: BackendAPI.LessonDetail?
    @State private var lines: [TranscriptLine] = []
    @State private var summary: AttributedString?
    @State private var peaks: [Double] = []
    @State private var shareText = ""
    @State private var loadError: Error?
    @State private var cachedAt: Date?
    @State private var isLoading = true
    @State private var isSummarizing = false
    @State private var summaryError: String?
    /// Whether the page follows the playhead. Any drag turns it off: being
    /// pulled back to the recording while reading ahead of it is worse than
    /// losing sight of the highlight, and re-arming is one tap.
    @State private var follow = true

    private var style: SubjectStyle { subjectStyle(for: info.subject) }
    private var hasAudio: Bool { detail?.hasAudio ?? info.hasAudio }

    /// The list already told us how long the lesson ran, so the timeline is
    /// drawable — and aimable — before the recording has been downloaded.
    private var duration: Double {
        player.duration > 0 ? player.duration : info.durationSeconds
    }

    var body: some View {
        layout
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(info.subject ?? info.title ?? "Stunde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                    .disabled(shareText.isEmpty)
                }
            }
            .task { await load() }
            .onDisappear { player.stop() }
    }

    @ViewBuilder
    private var layout: some View {
        if sizeClass == .compact {
            page
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasAudio {
                        LessonTransportBar(
                            peaks: peaks, duration: duration, tint: style.color,
                            player: player, playhead: playhead,
                            toggle: toggle, skip: skip
                        )
                    }
                }
        } else {
            HStack(spacing: 0) {
                LessonTimeRail(
                    info: info, style: style, peaks: peaks, duration: duration,
                    hasAudio: hasAudio, cachedAt: cachedAt,
                    player: player, playhead: playhead,
                    toggle: toggle, skip: skip
                )
                .frame(width: LessonMetrics.rail)
                Divider()
                page
            }
        }
    }

    // MARK: - The page

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sizeClass == .compact {
                        LessonHeadline(info: info, style: style, compact: true)
                            .padding(.bottom, 24)
                    }
                    summaryBlock
                    transcriptBlock
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 48)
                .frame(maxWidth: LessonMetrics.measure)
                .frame(maxWidth: .infinity)
            }
            // Reading wins over following. This runs before the scroll view
            // consumes the drag, and never fights a scroll it did not cause.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { _ in
                    if follow { follow = false }
                }
            )
            // `activeIndex`, never `currentTime`: this moves once per spoken
            // line instead of seven times a second.
            .onChange(of: player.activeIndex) { _, index in
                guard follow, let index else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// The lead text of the page, set larger than the record below it because
    /// it is the part anyone actually reads.
    @ViewBuilder
    private var summaryBlock: some View {
        if isSummarizing {
            SummaryPlaceholder()
        } else if let summary {
            Text(summary)
                .font(.title3)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isLoading {
            SummaryPlaceholder()
        } else {
            MissingSummary(isOnline: model.connectivity.isOnline, message: summaryError) {
                await writeSummary()
            }
        }
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.top, 32)
            transcriptHeading
                .padding(.top, 16)
                .padding(.bottom, 2)
            transcriptBody
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if !lines.isEmpty {
            transcriptLines
        } else if let loadError {
            ErrorState(loadError) { await load() }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else {
            Text("Von dieser Stunde wurde nichts aufgezeichnet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }

    private var transcriptLines: some View {
        let active = player.activeIndex
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                LessonTranscriptLine(
                    line: line,
                    tint: style.color,
                    isActive: active == line.id,
                    canPlay: hasAudio
                ) {
                    play(from: line.start)
                }
            }
        }
    }

    private var transcriptHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Transkript")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(countLabel)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            followControl
        }
    }

    private var countLabel: String {
        let count = lines.isEmpty ? info.segmentCount : lines.count
        return count == 1 ? "1 Beitrag" : "\(count) Beiträge"
    }

    @ViewBuilder
    private var followControl: some View {
        if hasAudio, !lines.isEmpty {
            Button {
                follow.toggle()
            } label: {
                Label(
                    follow ? "Folgt" : "Folgen",
                    systemImage: follow ? "arrow.down.circle.fill" : "arrow.down.circle"
                )
                .font(.footnote)
                .foregroundStyle(follow ? style.color : Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Playback

    private func play(from time: Double) {
        playhead.time = time
        Task {
            guard await player.ensureLoaded(api: api, lessonId: info.id) else { return }
            follow = true
            player.playFrom(time)
        }
    }

    private func toggle() {
        Task {
            guard await player.ensureLoaded(api: api, lessonId: info.id) else { return }
            if player.isPlaying {
                player.togglePlayPause()
                return
            }
            follow = true
            // Aiming the timeline before the recording had arrived left the
            // mark somewhere the player has never been.
            if abs(player.currentTime - playhead.time) > 0.5 {
                player.playFrom(playhead.time)
            } else {
                player.togglePlayPause()
            }
        }
    }

    private func skip(_ delta: Double) {
        let from = max(player.currentTime, playhead.time)
        let target = min(max(0, from + delta), max(duration - 0.2, 0))
        playhead.time = target
        player.seek(to: target)
    }

    // MARK: - Loading

    private func load() async {
        guard detail == nil else { return }
        // The list handed us a subject, a time and the opening of the summary.
        // Showing them straight away is why this page never opens as a spinner.
        if summary == nil, let excerpt = info.summaryExcerpt, !excerpt.isEmpty {
            summary = renderedMarkdown(excerpt)
        }
        loadError = nil
        isLoading = true
        let key = OfflineCache.Key.lesson(info.id)
        let storedAt = OfflineCache.savedAt(key: key)
        if let stored = OfflineCache.load(BackendAPI.LessonDetail.self, key: key) {
            apply(stored)
        }
        peaks = OfflineCache.load([Double].self, key: OfflineCache.Key.waveform(info.id)) ?? []
        do {
            let fetched = try await api.lesson(id: info.id)
            apply(fetched)
            OfflineCache.save(fetched, as: key)
            cachedAt = nil
        } catch {
            if detail == nil { loadError = error } else { cachedAt = storedAt }
        }
        isLoading = false
        await loadWaveform()
    }

    private func loadWaveform() async {
        guard hasAudio, peaks.isEmpty else { return }
        // A 404 here is the ordinary answer for a lesson recorded before the
        // server kept audio. There is nothing to tell the reader about it.
        guard let fetched = try? await api.waveform(id: info.id), !fetched.isEmpty else { return }
        peaks = fetched
        OfflineCache.save(fetched, as: OfflineCache.Key.waveform(info.id))
    }

    /// Everything the page needs is worked out here, once, when the lesson
    /// arrives — the Markdown, the export text, who each voice belongs to and
    /// which lines open a turn. A body that did any of it would do all of it
    /// again every time the playhead moved.
    private func apply(_ fetched: BackendAPI.LessonDetail) {
        detail = fetched
        let book = SpeakerBook.infer(
            from: fetched.segments,
            teacher: fetched.teacher ?? info.teacher
        )
        lines = TranscriptLine.build(from: fetched.segments, speakers: book)
        if let text = fetched.summary, !text.isEmpty {
            summary = renderedMarkdown(text)
        }
        shareText = lessonShareText(summary: fetched.summary, segments: fetched.segments)
        player.track(fetched.segments)
    }

    private func writeSummary() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        summaryError = nil
        defer { isSummarizing = false }
        do {
            let text = try await api.summarize(id: info.id)
            summary = renderedMarkdown(text)
            detail?.summary = text
            if let detail {
                OfflineCache.save(detail, as: OfflineCache.Key.lesson(info.id))
                shareText = lessonShareText(summary: text, segments: detail.segments)
            }
        } catch {
            summaryError = error.localizedDescription
        }
    }
}

// MARK: - Summary states

/// The shape of the paragraph that is coming. Used while the lesson loads and
/// while the server writes one, which takes seconds — long enough that a page
/// jumping from a spinner to three paragraphs reads as a different page.
struct SummaryPlaceholder: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach([1.0, 0.97, 0.93, 0.55], id: \.self) { fraction in
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 13)
                    .scaleEffect(x: fraction, anchor: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }
}

/// A lesson without a summary is an oddity — the server writes one when the
/// recording ends — so this is a sentence and a small button, not an empty
/// state taking over the page and handing the reader a job.
struct MissingSummary: View {
    let isOnline: Bool
    let message: String?
    let write: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Für diese Stunde wurde keine Zusammenfassung geschrieben.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await write() }
            } label: {
                Label("Nachtragen lassen", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isOnline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
