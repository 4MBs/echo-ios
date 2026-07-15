import SwiftUI

struct LessonDetailView: View {
    enum Tab: String, CaseIterable {
        case zusammenfassung = "Zusammenfassung"
        case transkript = "Transkript"
        case quiz = "Quiz"
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
        .paperScreen()
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
            case .quiz:
                QuizView(api: api, sessionIds: [info.id], title: nil)
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
