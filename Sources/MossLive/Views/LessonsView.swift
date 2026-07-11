import SwiftUI

/// Lessons browser: every past recording lives on the Fedora server; this
/// screen lists them, shows the full transcript, and generates a summary on
/// demand (cached server-side after the first time).
struct LessonsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var lessons: [BackendAPI.LessonInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("Lessons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Loading lessons…")
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(28)
        } else if lessons.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 34))
                    .foregroundStyle(.quaternary)
                Text("No recorded lessons yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            List(lessons) { lesson in
                NavigationLink {
                    LessonDetailView(api: api, info: lesson)
                } label: {
                    LessonRow(info: lesson)
                }
                .listRowBackground(Color.white.opacity(0.045))
            }
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
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
}

struct LessonRow: View {
    let info: BackendAPI.LessonInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .foregroundStyle(.teal)
                .frame(width: 34, height: 34)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Text("\(durationLabel) · \(info.segmentCount) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if info.hasSummary {
                Image(systemName: "text.badge.star")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.vertical, 3)
    }

    private var durationLabel: String {
        let minutes = Int(info.durationSeconds) / 60
        let seconds = Int(info.durationSeconds) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
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

    var body: some View {
        ZStack {
            AppBackground()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summarySection
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(detail.segments.enumerated()), id: \.element.id) { index, segment in
                        SegmentRow(
                            segment: segment,
                            isPartial: false,
                            showsSpeaker: index == 0 || detail.segments[index - 1].speaker != segment.speaker
                        )
                    }
                }
                .padding(14)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
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
