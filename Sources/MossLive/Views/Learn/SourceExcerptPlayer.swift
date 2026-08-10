import SwiftUI

/// The passage of the lesson a question was written from.
///
/// Every card carries `source_start_ms` and `source_end_ms`; every lesson with a
/// recording can be played. Until now those two facts met in a grey line of text
/// that said "Quelle: Mathematik · 12:30" and did nothing. This is the reason to
/// use Echo rather than a flashcard app: the answer you got wrong is twenty
/// seconds of the lesson away, and you come back to the same question.
struct SourceExcerptPlayer: View {
    let api: BackendAPI
    let lessonId: String
    let startMs: Int64
    let endMs: Int64?
    let onClose: () -> Void

    @State private var player = LessonAudioPlayer()
    @State private var loading = true
    @State private var failure: String?

    /// Three seconds of run-up, because a sentence rarely begins on the word the
    /// question was cut from.
    private static let leadIn: Double = 3
    /// How long an excerpt runs when the card names no end.
    private static let fallbackLength: Double = 25

    private var start: Double { max(0, Double(startMs) / 1000 - Self.leadIn) }

    private var end: Double {
        guard let endMs, Double(endMs) / 1000 > start else { return start + Self.fallbackLength }
        return Double(endMs) / 1000
    }

    private var elapsed: Double { min(max(0, player.currentTime - start), end - start) }

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            control
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: elapsed, total: max(1, end - start))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            Button {
                player.stop()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Wiedergabe schließen")
        }
        .padding(Theme.Space.inset)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(
            cornerRadius: Theme.Radius.control,
            style: .continuous
        ))
        .task { await begin() }
        .onDisappear { player.stop() }
        .onChange(of: player.currentTime) { _, time in
            // The excerpt owns its end: the recording keeps running underneath,
            // so playback stops where the question stopped — and the player
            // gets out of the way, leaving "Im Unterricht hören" for a second
            // listen rather than a finished bar nobody asked to keep.
            guard time >= end else { return }
            player.stop()
            onClose()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
        } else if failure != nil {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        } else {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
        }
    }

    private var title: String {
        if loading { return "Aufnahme wird geladen …" }
        if let failure { return failure }
        return "Im Unterricht · \(timecode(startMs))"
    }

    private func begin() async {
        loading = true
        defer { loading = false }
        guard await player.ensureLoaded(api: api, lessonId: lessonId) else {
            failure = "Aufnahme nicht verfügbar"
            return
        }
        player.playFrom(start)
    }

    private func timecode(_ milliseconds: Int64) -> String {
        let seconds = max(0, Int(milliseconds / 1000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
