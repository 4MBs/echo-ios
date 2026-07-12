import SwiftUI

/// Lessons browser: every past recording lives on the Fedora server; this
/// screen lists them, shows the full transcript, and generates a summary on
/// demand (cached server-side after the first time).
struct LessonsView: View {
    @Environment(AppModel.self) private var model

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var actionError: String?

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
                .navigationTitle("Lessons")
                .background(MossBackground())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(loading)
                        .accessibilityLabel("Refresh lessons")
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && lessons.isEmpty {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading your lessons…")
            }
        } else if let errorMessage, lessons.isEmpty {
            ContentUnavailableView {
                Label("Server unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glassProminent)
            }
        } else if lessons.isEmpty {
            ContentUnavailableView {
                Label("No lessons yet", systemImage: "books.vertical")
            } description: {
                Text("Finished recordings will appear here with their transcripts and summaries.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    }
                    HStack {
                        Text("RECENT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(lessons.count) saved")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4)
                    ForEach(lessons) { lesson in
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
                                Label("Delete Lesson", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
            .alert(
                "Couldn't delete lesson",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private func load() async {
        loading = true
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
                ProgressView("Loading transcript…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(info.startedAt.formatted(date: .abbreviated, time: .shortened))
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
                Text(info.hasAudio ? "Transcript · tap a line to replay it" : "Transcript")
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
                            index == activeIndex ? Color.purple.opacity(0.16) : .clear,
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
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 8) {
                Label("Summary", systemImage: "text.badge.star")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.purple)
                Text(renderedSummary(summary))
                    .font(.callout)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.purple.opacity(0.3), lineWidth: 1)
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
                    Text(summarizing ? "Summarizing this lesson…" : "Generate Summary")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(.purple)
                .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
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

    private func renderedSummary(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func shareText(_ detail: BackendAPI.LessonDetail) -> String {
        var parts: [String] = []
        if let summary {
            parts.append("SUMMARY\n\(summary)\n")
        }
        parts.append("TRANSCRIPT")
        parts.append(contentsOf: detail.segments.map { "\($0.speaker): \($0.text)" })
        return parts.joined(separator: "\n")
    }
}

// MARK: - Audio playback bar

struct LessonAudioBar: View {
    let player: LessonAudioPlayer
    let api: BackendAPI
    let lessonId: String

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    guard await player.ensureLoaded(api: api, lessonId: lessonId) else { return }
                    if !player.isPlaying, player.currentTime == 0 {
                        player.playFrom(0)
                    } else {
                        player.togglePlayPause()
                    }
                }
            } label: {
                Group {
                    if player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0)
                    .tint(.purple)
                HStack {
                    Text(timeString(player.currentTime))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(trailingLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(player.errorMessage != nil ? .red : .secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var trailingLabel: String {
        if player.errorMessage != nil { return "Audio unavailable" }
        if player.isReady { return timeString(player.duration) }
        return "Play recording"
    }

    private func timeString(_ time: Double) -> String {
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
