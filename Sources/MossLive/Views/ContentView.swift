import SwiftUI

/// Aufnahme: notebook-style live transcript with the record control underneath.
/// The connection status lives inside the transcript card's header; problems
/// (errors, interruptions) surface as banners above it.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
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
                TranscriptCard()
                    .overlay(alignment: .topTrailing) {
                        AnswerSticky()
                            .frame(maxWidth: 260)
                            .offset(x: -10, y: 52)
                    }
                if model.phase == .recording {
                    RecordingWaveform()
                }
                HStack {
                    Doodle(name: "doodle-calculator", size: 54, rotation: -8)
                    Spacer()
                    RecordButton()
                    Spacer()
                    Doodle(name: "doodle-pencil-ruler", size: 58, rotation: 10)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .animation(.snappy, value: model.bannerMessage)
            .paperScreen()
            .navigationTitle("Aufnahme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.phase == .recording, let started = model.recordingStartedAt {
                        RecordingTimer(startedAt: started)
                    }
                }
            }
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
        .paperCard()
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
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
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
        .paperCard()
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
            .paperCard()
    }
}

/// The mockup's Schnellnotiz sticky, repurposed: tapping it does exactly what
/// the widget does (answer the last seconds of the running recording) and
/// writes the AI answer onto the paper note.
struct AnswerSticky: View {
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
                    .stickyNote(rotation: 2)
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
                Text("KI-Antwort:")
                Text("Tippen, und die letzten \(Int(model.settings.contextSeconds)) s werden beantwortet.")
                    .font(Theme.handwriting(14))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Denkt nach…")
            }
        case .answer(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text("KI-Antwort:")
                Text(renderedMarkdown(text))
                    .font(Theme.handwriting(14))
                    .lineLimit(14)
                Text("Erneut tippen für eine neue Antwort")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .error(let message):
            Text(message)
                .font(Theme.handwriting(14))
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
                state = try await .answer(api.liveAnswer(contextSeconds: seconds))
            } catch {
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
                    .fill(Theme.accent.opacity(0.85))
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

/// Record control: one paper label with a wax seal pressed into it. Idle the
/// seal is ink; while recording it turns wax-red with a stop mark, so the
/// whole control reads as a single crafted object instead of a floating
/// circle next to loose text.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    private static let wax = Color(red: 0.60, green: 0.17, blue: 0.13)
    private static let waxDark = Color(red: 0.42, green: 0.10, blue: 0.08)

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
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: isActive
                                    ? [Self.wax, Self.waxDark]
                                    : [Theme.ink.opacity(0.88), Theme.ink],
                                center: UnitPoint(x: 0.38, y: 0.3),
                                startRadius: 2,
                                endRadius: 36
                            )
                        )
                        .frame(width: 52, height: 52)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.card.opacity(0.4), lineWidth: 1.4)
                                .padding(4)
                        )
                        .shadow(color: Theme.shadow.opacity(0.28), radius: 4, y: 2)
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.card)
                }
                Text(isActive ? "Aufnahme beenden" : "Aufnahme starten")
                    .font(Theme.handwriting(19))
                    .foregroundStyle(Theme.ink)
                    .padding(.trailing, 10)
            }
            .padding(.leading, 9)
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(Theme.card)
                    .overlay(
                        Image("paper-card")
                            .resizable()
                            .scaledToFill()
                            .opacity(0.4)
                    )
                    .clipShape(Capsule())
            }
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.28), lineWidth: 1.2))
            .shadow(color: Theme.shadow.opacity(0.16), radius: 8, y: 4)
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }
}

#Preview {
    MainSplitView()
        .environment(AppModel())
}
