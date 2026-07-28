import SwiftUI
import UIKit

/// One lesson, as two columns on a wide screen: the recording and what it was
/// about on the left, what was said on the right.
///
/// The page used to be one 700pt column down the middle of an iPad, which meant
/// the transcript — the longest thing here by an order of magnitude — was
/// reached by scrolling past everything else, and the two thirds of the display
/// either side of it were empty. Side by side, the summary and the player stay
/// on screen while the transcript is read, and the transcript gets a column of
/// its own to be long in.
///
/// Below `twoColumnWidth` (portrait, Slide Over, a split view) it folds back
/// into one column in the same order.
///
/// There is no switch between Zusammenfassung and Transkript: they are two
/// halves of one page, and a switch that rebuilt hundreds of transcript lines on
/// every tap was the slowest thing on the screen. The summary is parsed from
/// Markdown once when it arrives, and the spoken line comes from
/// `player.activeIndex`, which changes when the line changes rather than seven
/// times a second.
struct LessonDetailView: View {
    let api: BackendAPI
    let info: BackendAPI.LessonInfo

    @Environment(AppModel.self) private var model

    @State private var detail: BackendAPI.LessonDetail?
    /// Parsed once. The raw text is kept beside it for sharing and copying,
    /// which want characters rather than attributes.
    @State private var summary: ParsedSummary?
    @State private var summaryText: String?
    @State private var peaks: [Double] = []
    @State private var loadError: Error?
    @State private var summarizing = false
    @State private var errorMessage: String?
    @State private var player = LessonAudioPlayer()

    /// Where two columns start being wider than a readable measure each. An
    /// iPad in landscape is well past it; in portrait it is not.
    private static let twoColumnWidth: CGFloat = 880

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
        .navigationSubtitle(factsLine)
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
        GeometryReader { geo in
            if geo.size.width >= Self.twoColumnWidth {
                wide(detail)
            } else {
                narrow(detail)
            }
        }
        .groupedScreen()
    }

    private func wide(_ detail: BackendAPI.LessonDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    if info.hasAudio { playerCard }
                    summaryCard
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)

            TranscriptCard(
                segments: detail.segments,
                player: player,
                hasAudio: info.hasAudio,
                ownsScrolling: true,
                onPlay: play(from:)
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private func narrow(_ detail: BackendAPI.LessonDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if info.hasAudio { playerCard }
                    summaryCard
                    TranscriptCard(
                        segments: detail.segments,
                        player: player,
                        hasAudio: info.hasAudio,
                        ownsScrolling: false,
                        onPlay: play(from:)
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
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

    /// When it was, where, and with whom — under the title, where the system
    /// puts the second line about a thing rather than in a row of its own.
    private var factsLine: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        var parts = [
            start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                + ", " + start.formatted(date: .omitted, time: .shortened)
                + "–" + end.formatted(date: .omitted, time: .shortened),
        ]
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        if let teacher = info.teacher, !teacher.isEmpty { parts.append(teacher) }
        return parts.joined(separator: " · ")
    }

    private func play(from time: Double) {
        Task {
            if await player.ensureLoaded(api: api, lessonId: info.id) {
                player.playFrom(time)
            }
        }
    }

    // MARK: - Cards

    private var playerCard: some View {
        LessonPlayer(
            player: player,
            api: api,
            lessonId: info.id,
            peaks: peaks,
            knownDuration: info.durationSeconds
        )
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: 20)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryHeader
            if let summary {
                SummaryBody(summary: summary)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Zusammenfassung")
                .font(.headline)
            Spacer(minLength: 0)
            if let summaryText {
                CopyButton(text: summaryText)
            }
        }
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
        summary = text.map { ParsedSummary($0) }
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

// MARK: - Summary

/// A summary split into the paragraph that opens it and the points that follow.
///
/// The model is asked for prose and then a list, and it obliges — but as one
/// blob of Markdown, which rendered as an undifferentiated wall with bullet
/// characters in it. Splitting it here lets the list be a list.
struct ParsedSummary {
    let intro: AttributedString?
    let points: [AttributedString]

    init(_ text: String) {
        var introLines: [String] = []
        var points: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let point = Self.bulletBody(trimmed) {
                points.append(point)
            } else if !trimmed.isEmpty, points.isEmpty {
                introLines.append(trimmed)
            } else if !trimmed.isEmpty {
                // Prose after the list has started is a wrapped line, not a new
                // paragraph: it belongs to the point above it.
                points[points.count - 1] += " " + trimmed
            }
        }
        let intro = introLines.joined(separator: " ")
        self.intro = intro.isEmpty ? nil : renderedMarkdown(intro)
        self.points = points.map(renderedMarkdown)
    }

    /// The text of a list item, or nil when the line is not one. Covers what
    /// the model actually emits: a bullet character, a dash, an asterisk, or a
    /// number followed by a dot or a bracket.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["• ", "- ", "* ", "– ", "— "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let head = line[line.startIndex ..< dot]
        guard !head.isEmpty, head.count <= 2, head.allSatisfy(\.isNumber) else { return nil }
        let body = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }
}

private struct SummaryBody: View {
    let summary: ParsedSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let intro = summary.intro {
                Text(intro)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !summary.points.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(summary.points.enumerated()), id: \.offset) { index, text in
                        pointRow(index: index, text: text)
                    }
                }
            }
        }
    }

    /// A numbered chip rather than a bullet character: the points are the
    /// beats of the lesson in order, and a number says so where a dot does not.
    private func pointRow(index: Int, text: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accent.opacity(0.15), in: Circle())
            Text(text)
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

/// Copies once and says so, then goes back to being a button.
private struct CopyButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Label(
                copied ? "Kopiert" : "Kopieren",
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
            .font(.footnote)
            .foregroundStyle(copied ? Color.green : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transcript

/// What was said, as a searchable column of timestamped lines.
///
/// On a wide screen this owns its scrolling, so the transcript is a column that
/// scrolls beside a summary that stays put. Folded into one column it does not,
/// because a scroll view inside a scroll view is a trap for a finger.
private struct TranscriptCard: View {
    let segments: [TranscriptSegment]
    let player: LessonAudioPlayer
    let hasAudio: Bool
    let ownsScrolling: Bool
    let onPlay: (Double) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            if matches.isEmpty {
                noMatches
            } else if ownsScrolling {
                scrollingLines
            } else {
                lines
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 20)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Transkript")
                .font(.headline)
            Spacer(minLength: 0)
            Text("\(matches.count) Zeilen")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Button {
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transkript durchsuchen")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Transkript durchsuchen", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private var scrollingLines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                lines
            }
            .onChange(of: player.activeIndex) { _, index in
                guard player.isPlaying, let index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// Worked out once per redraw and handed to the loop: read inside the
    /// `ForEach` body it would be rebuilt for every row on the page.
    private var lines: some View {
        let rows = matches
        let lastIndex = rows.last?.index
        return LazyVStack(spacing: 0) {
            ForEach(rows, id: \.index) { match in
                line(match)
                    .id(match.index)
                if match.index != lastIndex {
                    Divider().padding(.leading, 74)
                }
            }
        }
    }

    private var noMatches: some View {
        Text(segments.isEmpty ? "Kein Transkript." : "Keine Zeile enthält „\(query)“.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    /// A line is only a control where there is something to play.
    @ViewBuilder
    private func line(_ match: Match) -> some View {
        if hasAudio {
            Button { onPlay(match.segment.t0) } label: { lineBody(match) }
                .buttonStyle(.plain)
        } else {
            lineBody(match)
        }
    }

    private func lineBody(_ match: Match) -> some View {
        let isActive = player.activeIndex == match.index
        return HStack(alignment: .top, spacing: 0) {
            // The bar is drawn always and made invisible when inactive, so the
            // text does not shift sideways as the playhead moves down the page.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isActive ? Theme.accent : .clear)
                .frame(width: 3)
                .padding(.vertical, 2)
            Text(timestamp(match.segment.t0))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(isActive ? Theme.accent : Theme.accent.opacity(0.75))
                .frame(width: 58, alignment: .leading)
                .padding(.leading, 11)
            Text(match.segment.text)
                .font(.callout)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .padding(.trailing, 6)
        .background(
            isActive ? Theme.accent.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private func timestamp(_ time: Double) -> String {
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// A segment with the index it has in the full transcript — searching must
    /// not renumber the lines the player highlights against.
    private struct Match {
        let index: Int
        let segment: TranscriptSegment
    }

    private var matches: [Match] {
        let all = segments.enumerated().map { Match(index: $0.offset, segment: $0.element) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.segment.text.localizedCaseInsensitiveContains(trimmed) }
    }
}
