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

/// The record control, built from measurements of Don Pardon's "Record Button
/// (Voice Messanger App)" rather than from an impression of it.
///
/// The artwork is not one shape with a glow around it. It is four translucent
/// shapes of different colours, each a different outline, overlapping so their
/// edges show and their overlaps tint each other. Each one here has its own
/// skeleton — its own set of harmonic amplitudes and phases — turning at its own
/// speed and in its own direction, and each answers the microphone with its own
/// delay, so a loud moment travels outwards through them instead of inflating
/// the whole thing at once.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    /// One translucent shape. Everything that could tie it to its neighbours —
    /// outline, colour, speed, direction, how far behind it hears — is its own.
    private struct Layer: Identifiable {
        let id: Int
        let skeleton: [Blob.Harmonic]
        let scale: CGFloat
        let color: Color
        let opacity: Double
        let drift: Double
        let offset: CGSize
        /// How many microphone samples behind the core this layer runs.
        let lag: Int
        /// How much of the level it takes up.
        let response: Double
    }

    private static let layers: [Layer] = [
        Layer(
            id: 0, skeleton: Blob.skeleton(seed: 7), scale: 1.26,
            color: Color(red: 254 / 255, green: 196 / 255, blue: 185 / 255),
            opacity: 0.14, drift: -0.6, offset: CGSize(width: 0, height: -4), lag: 9, response: 0.17
        ),
        Layer(
            id: 1, skeleton: Blob.skeleton(seed: 23), scale: 1.16,
            color: Color(red: 244 / 255, green: 169 / 255, blue: 162 / 255),
            opacity: 0.22, drift: 0.8, offset: CGSize(width: 5, height: 3), lag: 6, response: 0.13
        ),
        Layer(
            id: 2, skeleton: Blob.skeleton(seed: 61), scale: 1.08,
            color: Color(red: 253 / 255, green: 120 / 255, blue: 105 / 255),
            opacity: 0.30, drift: -1.1, offset: CGSize(width: -5, height: 3), lag: 3, response: 0.09
        ),
    ]

    // sampled across the core: it runs from a deeper red to an orange one
    private static let vivid = Color(red: 255 / 255, green: 58 / 255, blue: 50 / 255)
    private static let coral = Color(red: 255 / 255, green: 92 / 255, blue: 64 / 255)

    private static let diameter: CGFloat = 78
    /// Bar heights as measured, relative to the tallest. Widths and gaps are
    /// both 10.1% of the core's radius, and the tallest bar is 67.4% of it.
    private static let glyphBars: [CGFloat] = [0.30, 0.60, 1.00, 0.60, 0.30]

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
            // A timeline, not a repeating animation: the phase is read from the
            // clock every frame, so it never restarts and never jumps — which is
            // what made the first attempt stutter at the wrap.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                content(at: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 116, height: 116)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isActive)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }

    private func content(at time: TimeInterval) -> some View {
        let core = energy(lag: 0)

        return ZStack {
            ForEach(Self.layers) { layer in
                let level = energy(lag: layer.lag)
                Blob(
                    harmonics: layer.skeleton,
                    time: time,
                    swell: 1 + level * layer.response,
                    drift: layer.drift
                )
                .fill(layer.color.opacity(layer.opacity))
                .frame(
                    width: Self.diameter * layer.scale * (1 + level * 0.05),
                    height: Self.diameter * layer.scale * (1 + level * 0.05)
                )
                .offset(layer.offset)
            }

            Blob(harmonics: Blob.reference, time: time, swell: 1 + core * 0.45, drift: 1)
                .fill(
                    LinearGradient(
                        colors: [Self.vivid, Self.coral],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(
                    width: Self.diameter * (1 + core * 0.04),
                    height: Self.diameter * (1 + core * 0.04)
                )

            glyph(level: core)
        }
    }

    /// The room's loudness `lag` samples ago, smoothed over three of them. The
    /// levels arrive about sixteen times a second, so a lag of nine is a little
    /// over half a second behind — enough for the outer layer to visibly trail.
    private func energy(lag: Int) -> Double {
        guard model.phase == .recording else { return 0 }
        let levels = model.micLevels
        let end = levels.count - lag
        let start = max(0, end - 3)
        guard end > start else { return 0 }
        let window = levels[start ..< end]
        return min(1, Double(window.reduce(0, +)) / Double(window.count) * 1.7)
    }

    /// The waveform from the artwork. Its bars are not a separate colour —
    /// sampled, they are exactly the fill darkened by a fifth, so they are drawn
    /// as black at 20% and stay part of the shape wherever the gradient has got
    /// to. They ride the level while recording.
    private func glyph(level: Double) -> some View {
        let radius = Self.diameter / 2
        let unit = radius * 0.101  // measured: bar width and gap are both this
        let tallest = radius * 0.674
        let ride = isActive ? 0.78 + level * 0.9 : 1

        return HStack(alignment: .center, spacing: unit) {
            ForEach(Self.glyphBars.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(0.2))
                    .frame(width: unit, height: max(unit, tallest * Self.glyphBars[index] * ride))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// An outline in the style of the reference artwork: a circle whose radius is
/// bent by seven harmonics.
///
/// The reference set was measured by tracing the artwork's edge and taking the
/// Fourier transform of its radius — the fourth and fifth harmonics carry it, at
/// 3.5% and 3.4% of the radius, and the whole outline is only ±7.7% off a
/// circle. Getting those amplitudes wrong is the difference between this and a
/// rounded triangle. `skeleton(seed:)` makes siblings of it: same family of
/// amplitudes, different phases, so each layer is its own shape.
struct Blob: Shape {
    struct Harmonic {
        let amplitude: Double
        let phase: Double
    }

    /// Harmonics 1 through 7 of the artwork's own outline.
    static let reference: [Harmonic] = [
        Harmonic(amplitude: 0.0076, phase: -2.32),
        Harmonic(amplitude: 0.0199, phase: -1.74),
        Harmonic(amplitude: 0.0128, phase: -2.64),
        Harmonic(amplitude: 0.0350, phase: -3.00),
        Harmonic(amplitude: 0.0341, phase: -1.80),
        Harmonic(amplitude: 0.0097, phase: 0.22),
        Harmonic(amplitude: 0.0090, phase: 0.74),
    ]

    /// A sibling outline. Deterministic, so a shape does not change between
    /// frames — the same seed always gives the same skeleton.
    static func skeleton(seed: UInt64) -> [Harmonic] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 10_000) / 10_000
        }
        return reference.map { harmonic in
            Harmonic(amplitude: harmonic.amplitude * (0.7 + next() * 0.8), phase: next() * 2 * .pi)
        }
    }

    var harmonics: [Harmonic]
    /// Seconds. Each harmonic turns at its own speed, so the outline drifts.
    var time: Double
    /// Multiplies every amplitude: 1 is the artwork, higher is more agitated.
    var swell: Double = 1
    /// Speed and direction of the drift, so no two layers turn together.
    var drift: Double = 1

    func path(in rect: CGRect) -> Path {
        let reach = harmonics.reduce(0) { $0 + $1.amplitude }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // leave room for the largest bulge, so nothing clips at the frame
        let radius = min(rect.width, rect.height) / 2 / (1 + reach * swell)
        let steps = 64

        let points: [CGPoint] = (0 ..< steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            var bend = 0.0
            for (index, harmonic) in harmonics.enumerated() {
                let order = Double(index + 1)
                let turn = time * drift * (0.21 + 0.05 * order)
                bend += harmonic.amplitude * swell * cos(order * angle + harmonic.phase + turn)
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
