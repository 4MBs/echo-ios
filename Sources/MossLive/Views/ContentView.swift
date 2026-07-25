import SwiftUI

/// Aufnahme: the live transcript fills the screen (like a Notes page); the
/// record control lives in a glass bar at the bottom, Voice-Memos style.
/// Problems (errors, interruptions) surface as banners at the top.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if case .error(let message) = model.phase {
                    BannerView(text: message, color: .red)
                }
                if let banner = model.bannerMessage {
                    BannerView(text: banner, color: .orange)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.phase == .reconnecting, model.bufferedSeconds >= 1 {
                    BufferingBanner(seconds: model.bufferedSeconds)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.timetable.enabled {
                    CurrentLessonBanner()
                }
                TranscriptPane()
                    .overlay(alignment: .topTrailing) {
                        AnswerCard()
                            .frame(maxWidth: 280)
                            .padding(.top, 8)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecordControlBar()
            }
            .animation(.snappy, value: model.bannerMessage)
            // The navigation bar has to stay: it carries the system button that
            // hides and reveals the sidebar, which is why that button was
            // missing here alone. Inline, so it costs as little height as
            // possible and the transcript still reads as a full page.
            .navigationTitle("Aufnahme")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Bottom glass bar: connection status on the left, the record button in the
/// middle, timer/latency on the right, live waveform above while recording.
struct RecordControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if model.phase == .recording {
                RecordingWaveform()
            }
            HStack(spacing: 12) {
                statusView
                    .frame(maxWidth: .infinity, alignment: .leading)
                RecordButton()
                trailingView
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusView: some View {
        if model.phase == .recording {
            HStack(spacing: 8) {
                LivePill()
                Text(model.isTranscribing ? "wird transkribiert…" : "Aufnahme läuft")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            StatusLabel(phase: model.phase)
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        if model.phase == .recording, let started = model.recordingStartedAt {
            RecordingTimer(startedAt: started)
        } else if let rtt = model.lastRoundTripMs, model.phase == .connected {
            Text("\(Int(rtt)) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Tier 2: the lesson happening now (or the next one), from the timetable.
struct CurrentLessonBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let current = model.timetable.current {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(current.title).font(.subheadline.weight(.semibold))
                    if current.cancelled {
                        statusTag("entfällt", .red)
                    } else if current.substitution {
                        statusTag("Vertretung", .orange)
                    }
                }
                Text(subtitle(current)).font(.caption).foregroundStyle(.secondary)
            }
        } else if let next = model.timetable.next {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gerade kein Unterricht").font(.subheadline.weight(.semibold))
                Text("Als Nächstes: \(next.title) · \(next.start)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Kein Unterricht heute").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ lesson: BackendAPI.Lesson) -> String {
        var parts = ["\(lesson.start)-\(lesson.end)"]
        if !lesson.room.isEmpty { parts.append("Raum \(lesson.room)") }
        if !lesson.teacher.isEmpty { parts.append(lesson.teacher) }
        return parts.joined(separator: " · ")
    }

    private func statusTag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct RecordingTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Reassurance during an outage: recording continues, audio is buffered on
/// the iPad and replayed once the connection is back — nothing is lost.
struct BufferingBanner: View {
    let seconds: Double

    var body: some View {
        Label(
            String(
                format: "Offline: Aufnahme läuft weiter und wird gepuffert (%d:%02d)",
                Int(seconds) / 60, Int(seconds) % 60
            ),
            systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct BannerView: View {
    let text: String
    var color: Color = .orange

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Floating answer card over the transcript: tapping it does exactly what
/// the widget does (answer the last seconds of the running recording).
struct AnswerCard: View {
    @Environment(AppModel.self) private var model

    private enum NoteState: Equatable {
        case idle
        case loading
        case answer(String)
        case error(String)
    }

    @State private var state: NoteState = .idle

    var body: some View {
        if model.phase == .recording || state != .idle {
            Button(action: ask) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(state == .loading)
            .accessibilityLabel("KI-Antwort zu den letzten Sekunden")
            .onChange(of: model.phase) {
                if model.phase != .recording { state = .idle }
            }
            .animation(.snappy, value: state)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                Label("KI-Antwort", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text("Tippen, und die letzten \(Int(model.settings.contextSeconds)) s werden beantwortet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Denkt nach…")
                    .font(.subheadline)
            }
        case .answer(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("KI-Antwort", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(renderedMarkdown(text))
                    .font(.footnote)
                    .lineLimit(14)
                Text("Erneut tippen für eine neue Antwort")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .error(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func ask() {
        guard state != .loading else { return }
        guard model.phase == .recording else {
            state = .error("Starte zuerst eine Aufnahme.")
            return
        }
        let api = BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
        let seconds = Int(model.settings.contextSeconds)
        state = .loading
        Task {
            do {
                let answer = try await api.liveAnswer(contextSeconds: seconds)
                // stopping the recording resets the note to .idle — a late
                // response must not bring it back
                guard state == .loading else { return }
                state = .answer(answer)
            } catch {
                guard state == .loading else { return }
                let message = error.localizedDescription
                state = .error(
                    message.contains("no active recording")
                        ? "Starte zuerst eine Aufnahme." : message
                )
            }
        }
    }
}

// MARK: - Controls

/// Live waveform strip while recording: every bar is a real microphone level
/// (RMS, ~16/s), so silence is flat and speech visibly moves. Newest at the
/// right.
struct RecordingWaveform: View {
    @Environment(AppModel.self) private var model

    private static let barCount = 72

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 2, height: 3 + CGFloat(level(at: index)) * 23)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.06), value: model.micLevels)
        .accessibilityLabel("Mikrofonpegel")
    }

    /// Levels right-aligned: the newest sample is the rightmost bar.
    private func level(at index: Int) -> Float {
        let levels = model.micLevels
        let offset = Self.barCount - levels.count
        guard index >= offset else { return 0 }
        return levels[index - offset]
    }
}

/// Record control: a single prominent capsule button. Blue at rest, red
/// while a session is active — the system convention for recording.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    private var isActive: Bool {
        switch model.phase {
        case .recording, .connecting, .reconnecting, .connected: true
        default: false
        }
    }

    var body: some View {
        Button {
            if isActive {
                model.stopRecording()
            } else {
                Task { await model.startRecording() }
            }
        } label: {
            Label(
                isActive ? "Aufnahme beenden" : "Aufnahme starten",
                systemImage: isActive ? "stop.fill" : "mic.fill"
            )
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(isActive ? .red : .accentColor)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
}
