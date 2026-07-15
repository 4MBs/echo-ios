import SwiftUI

/// SF Symbol tile for a school subject (best-effort keyword match).
func subjectSymbol(for subject: String?) -> String {
    guard let subject = subject?.lowercased() else { return "graduationcap.fill" }
    let map: [(String, String)] = [
        ("mathe", "x.squareroot"), ("math", "x.squareroot"),
        ("physik", "atom"),
        ("chemie", "testtube.2"),
        ("bio", "leaf.fill"),
        ("informatik", "desktopcomputer"),
        ("deutsch", "text.book.closed.fill"),
        ("englisch", "character.book.closed.fill"),
        ("franz", "character.book.closed.fill"),
        ("latein", "character.book.closed.fill"),
        ("spanisch", "character.book.closed.fill"),
        ("geschichte", "clock.fill"),
        ("erdkunde", "globe.europe.africa.fill"),
        ("geo", "globe.europe.africa.fill"),
        ("musik", "music.note"),
        ("kunst", "paintpalette.fill"),
        ("sport", "figure.run"),
        ("religion", "book.closed.fill"),
        ("ethik", "person.2.fill"),
        ("politik", "building.columns.fill"),
        ("wirtschaft", "chart.line.uptrend.xyaxis"),
    ]
    for (keyword, symbol) in map where subject.contains(keyword) {
        return symbol
    }
    return "graduationcap.fill"
}

/// The backend asks Gemini for plain text, but render any inline Markdown
/// that slips through instead of showing raw asterisks.
func renderedMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// Shared export text for a lesson (used by the detail and summary screens).
func lessonShareText(summary: String?, segments: [TranscriptSegment]) -> String {
    var parts: [String] = []
    if let summary {
        parts.append("ZUSAMMENFASSUNG\n\(summary)\n")
    }
    parts.append("TRANSKRIPT")
    parts.append(contentsOf: segments.map(\.text))
    return parts.joined(separator: "\n")
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
            .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0)
                    .tint(Theme.accent)
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
        .paperCard(cornerRadius: 14)
    }

    private var trailingLabel: String {
        if player.errorMessage != nil { return "Audio nicht verfügbar" }
        if player.isReady { return timeString(player.duration) }
        return "Aufnahme abspielen"
    }

    private func timeString(_ time: Double) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Shared list states

struct ErrorState: View {
    let message: String
    let retry: (() async -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Erneut versuchen") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
    }
}

struct EmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }
}

/// One lesson as a notebook card: subject tile, title, meta line, and small
/// icons for what the lesson already has (audio, summary).
struct LessonRow: View {
    let info: BackendAPI.LessonInfo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: subjectSymbol(for: info.subject))
                .font(.system(size: 19))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title ?? info.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if info.hasAudio {
                    Image(systemName: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                if info.hasSummary {
                    Image(systemName: "text.badge.star")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(cornerRadius: 14)
    }

    private var durationLabel: String {
        let minutes = Int(info.durationSeconds) / 60
        let seconds = Int(info.durationSeconds) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
    }

    /// When the lesson is titled from the timetable, the date/room become the
    /// secondary line; otherwise fall back to duration.
    private var secondaryLine: String {
        var parts = [info.startedAt.formatted(date: .abbreviated, time: .shortened), durationLabel]
        if let room = info.room, !room.isEmpty { parts.append("Raum \(room)") }
        return parts.joined(separator: " · ")
    }
}
