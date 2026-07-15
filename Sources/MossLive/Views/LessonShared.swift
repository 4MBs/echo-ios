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
    parts.append(contentsOf: segments.map { "\($0.speaker): \($0.text)" })
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
