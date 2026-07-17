import SwiftUI

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
                    .groupedScreen()
            } else {
                ProgressView("Lade Stunde…")
                    .groupedScreen()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The segmented switch sits in the navigation bar, like in the
            // system apps; the lesson name lives in the info section below.
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
            }
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
        List {
            switch tab {
            case .zusammenfassung:
                infoSection
                summarySection
            case .transkript:
                transcriptSection(detail)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab == .transkript, info.hasAudio {
                LessonAudioBar(player: audioPlayer, api: api, lessonId: info.id)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    // MARK: Info

    private var infoSection: some View {
        Section {
            HStack(spacing: 12) {
                let style = subjectStyle(for: info.subject)
                IconTile(systemName: style.symbol, color: style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title ?? "Aufnahme")
                        .font(.headline)
                    Text(dateLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if let teacher = info.teacher, !teacher.isEmpty {
                LabeledContent("Lehrkraft", value: teacher)
            }
            if let room = info.room, !room.isEmpty {
                LabeledContent("Raum", value: room)
            }
            LabeledContent("Dauer", value: durationText)
        }
    }

    private var dateLine: String {
        let start = info.startedAt
        let end = start.addingTimeInterval(info.durationSeconds)
        return start.formatted(date: .long, time: .omitted)
            + " · \(start.formatted(date: .omitted, time: .shortened)) – "
            + end.formatted(date: .omitted, time: .shortened)
    }

    private var durationText: String {
        let minutes = Int(info.durationSeconds) / 60
        return minutes > 0 ? "\(minutes) Minuten" : "\(Int(info.durationSeconds)) Sekunden"
    }

    // MARK: Zusammenfassung

    @ViewBuilder
    private var summarySection: some View {
        Section("Zusammenfassung") {
            if let summary {
                Text(renderedMarkdown(summary))
                    .font(.callout)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 12) {
                    Text("Für diese Stunde gibt es noch keine Zusammenfassung.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await generateSummary() }
                    } label: {
                        HStack(spacing: 8) {
                            if summarizing { ProgressView() }
                            Text(summarizing ? "Wird erstellt…" : "Zusammenfassung erstellen")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(summarizing)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
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

    private func transcriptSection(_ detail: BackendAPI.LessonDetail) -> some View {
        let activeIndex = audioPlayer.activeSegmentIndex(in: detail.segments)
        return Section {
            ForEach(Array(detail.segments.enumerated()), id: \.element.id) { index, segment in
                Button {
                    guard info.hasAudio else { return }
                    Task {
                        if await audioPlayer.ensureLoaded(api: api, lessonId: info.id) {
                            audioPlayer.playFrom(segment.t0)
                        }
                    }
                } label: {
                    SegmentRow(segment: segment, isPartial: false)
                }
                .buttonStyle(.plain)
                .listRowBackground(index == activeIndex ? Theme.accent.opacity(0.12) : nil)
            }
        } footer: {
            if info.hasAudio {
                Text("Zeile antippen, um sie ab dieser Stelle anzuhören.")
            }
        }
    }
}
