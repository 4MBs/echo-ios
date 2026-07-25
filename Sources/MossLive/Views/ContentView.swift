import SwiftUI

/// Aufnahme, arranged the way Apple's own recording apps are: the transcript is
/// the page and owns the whole screen, and everything about the recording —
/// level meter, elapsed time, status, the record control — is gathered into one
/// deck along the bottom edge. Notices sit above the transcript, pinned, so a
/// warning never scrolls away.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            TranscriptPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).ignoresSafeArea())
                .safeAreaInset(edge: .top, spacing: 0) { notices }
                .safeAreaInset(edge: .bottom, spacing: 0) { RecordDeck() }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { AnswerButton() } }
                .animation(.snappy, value: model.bannerMessage)
                // No title: the sidebar already says which screen this is, and a
                // second "Aufnahme" across the top of an otherwise empty page had
                // nothing to do. The bar itself has to stay — it carries the
                // system button that hides and reveals the sidebar.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hasNotices: Bool {
        if case .error = model.phase { return true }
        if model.bannerMessage != nil { return true }
        if model.phase == .reconnecting, model.bufferedSeconds >= 1 { return true }
        return model.timetable.enabled && model.phase == .recording
    }

    @ViewBuilder
    private var notices: some View {
        if hasNotices {
            VStack(spacing: 8) {
                if case .error(let message) = model.phase {
                    NoticeBanner(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                }
                if let banner = model.bannerMessage {
                    NoticeBanner(text: banner, systemImage: "info.circle.fill", tint: .orange)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.phase == .reconnecting, model.bufferedSeconds >= 1 {
                    NoticeBanner(
                        text: String(
                            format: "Offline: Aufnahme läuft weiter und wird gepuffert (%d:%02d)",
                            Int(model.bufferedSeconds) / 60, Int(model.bufferedSeconds) % 60
                        ),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .orange
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // The page is left blank at rest, so this only rides along once
                // the recording has started and it says what is being recorded.
                if model.timetable.enabled, model.phase == .recording {
                    CurrentLessonBanner()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - The deck

/// The recording dock. It says as little as it can get away with: while running,
/// the meter, the clock and one caption; at rest, nothing but the control. The
/// connection is not reported at rest either — the app is idle and disconnected
/// almost all of the time, and announcing "Getrennt" made a normal state look
/// like a fault.
struct RecordDeck: View {
    @Environment(AppModel.self) private var model

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        VStack(spacing: 12) {
            if isRecording {
                RecordingWaveform()
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                if let started = model.recordingStartedAt {
                    RecordingTimer(startedAt: started)
                        .transition(.opacity)
                }
            }
            caption
            RecordButton()
        }
        .padding(.horizontal, 24)
        .padding(.top, isRecording ? 14 : 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: isRecording)
    }

    /// One line under the clock, and the only place state is spelled out. The
    /// round trip joins it rather than sitting in its own corner, so the dock
    /// stays a single centred column.
    @ViewBuilder
    private var caption: some View {
        switch model.phase {
        case .recording:
            Text(recordingCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        case .connecting, .reconnecting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(model.phase.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .connected:
            Text("Verbunden")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .disconnected, .error:
            EmptyView()
        }
    }

    private var recordingCaption: String {
        var parts = [model.isTranscribing ? "wird transkribiert…" : "Aufnahme läuft"]
        if let rtt = model.lastRoundTripMs { parts.append("\(Int(rtt)) ms") }
        return parts.joined(separator: " · ")
    }
}

/// The record control, rebuilt from Don Pardon's "Record Button (Voice
/// Messanger App)" rather than from an impression of it: the outline, the bar
/// geometry and the colours were measured off the artwork.
///
/// The shape is a circle whose radius is bent by the first seven harmonics of
/// the original outline, at the amplitudes and phases they actually have there.
/// It matters that they are small — the real shape is only ±7.7% off a circle,
/// and guessing at it produced a rounded triangle. Each harmonic then drifts at
/// its own rate, so the outline keeps moving without ever repeating visibly.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    // sampled from the artwork; the palette it publishes agrees
    private static let vivid = Color(red: 255 / 255, green: 45 / 255, blue: 38 / 255)
    private static let coral = Color(red: 255 / 255, green: 96 / 255, blue: 66 / 255)

    private static let diameter: CGFloat = 78
    /// Bar heights as measured, relative to the tallest. Widths and gaps are
    /// both 10.1% of the blob's radius, and the tallest bar is 67.4% of it.
    private static let glyphBars: [CGFloat] = [0.30, 0.60, 1.00, 0.60, 0.30]

    private var isActive: Bool {
        switch model.phase {
        case .recording, .connecting, .reconnecting, .connected: true
        default: false
        }
    }

    /// How loudly the room is speaking, smoothed. The blob swells with it and
    /// the bars ride on it, so the control is showing the recording rather than
    /// just decorating it.
    private var energy: Double {
        guard model.phase == .recording else { return 0 }
        let recent = model.micLevels.suffix(4)
        guard !recent.isEmpty else { return 0 }
        let mean = Double(recent.reduce(0, +)) / Double(recent.count)
        return min(1, mean * 1.7)
    }

    var body: some View {
        Button {
            if isActive {
                model.stopRecording()
            } else {
                Task { await model.startRecording() }
            }
        } label: {
            // A timeline, not a repeating animation: the phase is read from the
            // clock every frame, so it never restarts and never jumps — which is
            // what made the first attempt stutter at the wrap.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                content(at: time)
            }
            .frame(width: 112, height: 112)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isActive)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }

    private func content(at time: TimeInterval) -> some View {
        let swell = 1 + energy * 0.5
        let size = Self.diameter * (1 + energy * 0.06)

        return ZStack {
            // The artwork's halo is two more of the same outline, larger and
            // slower and turning the other way, reaching 1.34x the radius. There
            // it sits on white and reads as a shadow; here it sits on black, so
            // it is tinted with the blob's own colour and reads as light. Softened
            // in one pass rather than two — a pale hard-edged copy of a shape
            // this round just looks like a ring around it.
            ZStack {
                Blob(time: time * 0.5, swell: 1.3, seed: 2.1)
                    .fill(Self.vivid.opacity(isActive ? 0.20 : 0.13))
                    .frame(width: size * 1.34, height: size * 1.34)
                Blob(time: -time * 0.7, swell: 1.15, seed: 4.4)
                    .fill(Self.coral.opacity(isActive ? 0.26 : 0.17))
                    .frame(width: size * 1.13, height: size * 1.13)
            }
            .blur(radius: 9)

            Blob(time: time, swell: swell)
                .fill(
                    LinearGradient(
                        colors: [Self.vivid, Self.coral],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: Self.vivid.opacity(0.22), radius: 8, y: 3)

            glyph
        }
    }

    /// The waveform from the artwork. Its bars are not a separate colour — they
    /// are the fill darkened by a fifth, which is how they stay part of the blob
    /// wherever the gradient has got to.
    private var glyph: some View {
        let radius = Self.diameter / 2
        let unit = radius * 0.101  // measured: bar width and gap are both this
        let tallest = radius * 0.674
        let ride = 0.78 + energy * 0.9

        return HStack(alignment: .center, spacing: unit) {
            ForEach(Self.glyphBars.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(0.2))
                    .frame(
                        width: unit,
                        height: max(unit, tallest * Self.glyphBars[index] * (isActive ? ride : 1))
                    )
            }
        }
        .animation(.easeOut(duration: 0.12), value: energy)
    }
}

/// The outline of the reference artwork, as a shape.
///
/// Measured by tracing its edge and taking the Fourier transform of the radius:
/// the fourth and fifth harmonics carry it, at 3.5% and 3.4% of the radius, with
/// five smaller ones filling in. Reproducing those amplitudes is the difference
/// between this and a wobbly triangle.
struct Blob: Shape {
    /// (amplitude as a fraction of the radius, phase) for harmonics 1 through 7.
    private static let harmonics: [(amplitude: Double, phase: Double)] = [
        (0.0076, -2.32),
        (0.0199, -1.74),
        (0.0128, -2.64),
        (0.0350, -3.00),
        (0.0341, -1.80),
        (0.0097, 0.22),
        (0.0090, 0.74),
    ]
    private static let reach = harmonics.reduce(0) { $0 + $1.amplitude }

    /// Seconds. Each harmonic turns at its own speed, so the outline drifts.
    var time: Double
    /// Multiplies every amplitude: 1 is the artwork, higher is more agitated.
    var swell: Double = 1
    /// Rotates the whole outline, to tell the stacked copies apart.
    var seed: Double = 0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // leave room for the largest bulge, so nothing clips at the frame
        let radius = min(rect.width, rect.height) / 2 / (1 + Self.reach * swell)
        let steps = 60

        let points: [CGPoint] = (0 ..< steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi + seed
            var bend = 0.0
            for (index, harmonic) in Self.harmonics.enumerated() {
                let order = Double(index + 1)
                let drift = time * (0.21 + 0.05 * order)
                bend += harmonic.amplitude * swell * cos(order * angle + harmonic.phase + drift)
            }
            let distance = radius * (1 + bend)
            return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        }

        // Quad curves between the midpoints, each sample as the control point:
        // a closed curve with no corners anywhere.
        var path = Path()
        path.move(to: midpoint(points[steps - 1], points[0]))
        for index in 0 ..< steps {
            let current = points[index]
            let next = points[(index + 1) % steps]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// Presses dip the control slightly. `.plain` gives no feedback at all, and a
/// control this large feels dead without it.
private struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Live level meter: every bar is a real microphone reading (RMS, ~16/s),
/// centred on its own axis so speech opens symmetrically and silence is a thin
/// line. Newest sample at the right.
struct RecordingWaveform: View {
    @Environment(AppModel.self) private var model

    private static let barCount = 72

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0 ..< Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: 3, height: 4 + CGFloat(level(at: index)) * 36)
            }
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity)
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

/// The elapsed time, and the largest type on the screen while recording.
struct RecordingTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .accessibilityLabel("Aufnahmedauer \(seconds / 60) Minuten \(seconds % 60) Sekunden")
        }
    }
}

// MARK: - Notices

/// One shape for every notice on this screen. Colour is carried by the icon and
/// a hairline rather than by a tinted wash, so a warning reads as urgent without
/// the screen turning into a traffic light.
struct NoticeBanner: View {
    let text: String
    let systemImage: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 0.5)
        }
    }
}

/// The lesson happening now, or the next one, from the timetable.
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

// MARK: - Ask the AI

/// The same thing the widget does — answer the last N seconds of the running
/// recording — moved off the transcript and into the toolbar, where an occasional
/// action belongs. The answer arrives in a popover instead of a card parked over
/// the text.
struct AnswerButton: View {
    @Environment(AppModel.self) private var model

    private enum NoteState: Equatable {
        case idle
        case loading
        case answer(String)
        case failed(String)
    }

    @State private var state: NoteState = .idle
    @State private var showingAnswer = false

    private var isRecording: Bool { model.phase == .recording }

    var body: some View {
        // Nothing can be answered without a running recording, and a permanently
        // greyed-out control reads as broken rather than as unavailable.
        Group {
            if isRecording {
                Button {
                    showingAnswer = true
                    if state == .idle { ask() }
                } label: {
                    Label("KI-Antwort", systemImage: "sparkles")
                }
                .popover(isPresented: $showingAnswer) { answerSheet }
                .accessibilityLabel("KI-Antwort zu den letzten Sekunden")
            }
        }
        // On the Group, not on the button: the button goes away when the
        // recording stops, and a modifier that leaves with it would never fire —
        // leaving the last answer to reappear at the start of the next lesson.
        .onChange(of: model.phase) {
            if !isRecording {
                state = .idle
                showingAnswer = false
            }
        }
    }

    private var answerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Die letzten \(Int(model.settings.contextSeconds)) Sekunden", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            switch state {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Denkt nach…").font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .answer(let text):
                ScrollView {
                    Text(renderedMarkdown(text))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Neu fragen", systemImage: "arrow.clockwise", action: ask)
                    .disabled(state == .loading)
                Spacer()
                if case .answer(let text) = state {
                    Button("Kopieren", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }
                }
            }
            .font(.subheadline)
            .labelStyle(.titleAndIcon)
        }
        .padding(16)
        .frame(width: 380)
        .presentationCompactAdaptation(.popover)
        .animation(.snappy, value: state)
    }

    private func ask() {
        guard state != .loading, isRecording else { return }
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
                // stopping the recording resets the note — a late response
                // must not bring it back
                guard state == .loading else { return }
                state = .answer(answer)
            } catch {
                guard state == .loading else { return }
                let message = error.localizedDescription
                state = .failed(
                    message.contains("no active recording")
                        ? "Starte zuerst eine Aufnahme." : message
                )
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
}
