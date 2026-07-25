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
            if isRecording, let started = model.recordingStartedAt {
                RecordingTimer(startedAt: started)
                    .transition(.opacity)
            }
            caption
            RecordButton()
        }
        .padding(.horizontal, 24)
        .padding(.top, isRecording ? 12 : 16)
        .padding(.bottom, 8)
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

/// The record control: a soft blob under a red gradient, with two paler blobs
/// drifting behind it and a waveform in the middle.
///
/// Modelled on Don Pardon's "Record Button (Voice Messanger App)", down to its
/// palette. Nothing here is an image — the blob is a circle whose radius is bent
/// by two sine waves, so it can be animated by moving their phase, and it stays
/// sharp at any size.
///
/// The phase is read from a timeline rather than driven by a repeating
/// animation. The shape is identical; what goes away is the jump every time such
/// an animation reaches its end and starts over.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    /// The shot's palette, as hue/saturation/brightness so the tint setting can
    /// turn all four together and keep them related to each other.
    private static let vivid = (hue: 0.0055, saturation: 0.945, brightness: 0.996)
    private static let coral = (hue: 0.0067, saturation: 0.680, brightness: 0.992)
    private static let deep = (hue: 0.0046, saturation: 0.955, brightness: 0.604)
    private static let pale = (hue: 0.0145, saturation: 0.336, brightness: 0.957)

    /// Everything here is slow, and the microphone reports sixteen times a
    /// second, so thirty frames carries all of it.
    private static let frameRate = 30.0

    private var isActive: Bool {
        switch model.phase {
        case .recording, .connecting, .reconnecting, .connected: true
        default: false
        }
    }

    private func tint(_ colour: (hue: Double, saturation: Double, brightness: Double)) -> Color {
        Color(
            hue: (colour.hue + model.settings.recordButtonHue).truncatingRemainder(dividingBy: 1),
            saturation: colour.saturation,
            brightness: colour.brightness
        )
    }

    var body: some View {
        Button {
            if isActive {
                model.stopRecording()
            } else {
                Task { await model.startRecording() }
            }
        } label: {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / Self.frameRate)) { context in
                    content(at: context.date.timeIntervalSinceReferenceDate)
                }
                Waveform(color: tint(Self.deep).opacity(0.85))
            }
            .frame(width: 108, height: 108)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isActive)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }

    private func content(at time: TimeInterval) -> some View {
        // one slow turn of the phase, forever — the blob never settles
        let phase = time * 2 * .pi / 7
        let heard = level(lag: 0, window: 3)

        return ZStack {
            halo(phase: phase, level: heard)

            Blob(phase: phase, wobble: 0.055 + 0.035 * heard)
                .fill(
                    LinearGradient(
                        colors: [tint(Self.vivid), tint(Self.coral)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 78, height: 78)
                .shadow(color: tint(Self.vivid).opacity(0.45), radius: 16, y: 6)
        }
        // One rasterisation for the blob and its halo, on the GPU, instead of a
        // pass per blur. The waveform is deliberately outside it: rasterising a
        // view every frame is the opposite of what its animation wants.
        .drawingGroup()
    }

    /// Two paler blobs, larger and slower, turning the wrong way — the halo in
    /// the shot, and the only thing moving on the screen at rest.
    private func halo(phase: Double, level heard: Double) -> some View {
        ZStack {
            Blob(phase: -phase * 0.8 + 1.4, wobble: 0.07)
                .fill(tint(Self.pale).opacity(0.22 + 0.12 * heard))
                .frame(width: 102, height: 102)
                .blur(radius: 3)
            Blob(phase: phase * 0.55 + 3.1, wobble: 0.08)
                .fill(tint(Self.pale).opacity(0.16 + 0.10 * heard))
                .frame(width: 92, height: 92)
                .blur(radius: 2)
        }
    }

    /// The room's loudness `lag` samples ago, averaged over `window` of them.
    /// Averaging is the smoothing, and a different window per bar is why they
    /// settle raggedly instead of together. Levels arrive about sixteen times a
    /// second, so six samples is a bit over a third of a second behind.
    private func level(lag: Int, window: Int) -> Double {
        guard model.phase == .recording else { return 0 }
        let levels = model.micLevels
        let end = levels.count - lag
        let start = max(0, end - window)
        guard end > start else { return 0 }
        let slice = levels[start ..< end]
        return min(1, Double(slice.reduce(0, +)) / Double(slice.count) * 1.7)
    }
}

/// The waveform in the middle of the control.
///
/// It is not drawn frame by frame. Recomputing a height on every tick of a
/// timeline caps the motion at that timeline's rate, and the microphone only
/// reports sixteen times a second, so the bars could only ever step — which is
/// what made them look slower than everything around them.
///
/// Instead each bar declares where it is going and lets the system get it there:
/// the idle sway is a repeating animation, and the level sets a target that is
/// eased towards. Both are interpolated on the render server at the display's
/// own rate, so the bars run at 120Hz on a ProMotion iPad while costing nothing
/// per frame.
struct Waveform: View {
    @Environment(AppModel.self) private var model

    let color: Color

    /// One bar. Every field differs between the five, so nothing about them can
    /// move in step: their resting height, how far and how fast they sway, when
    /// their sway starts, how far back they listen, and how hard they react.
    private struct Bar: Identifiable {
        let id: Int
        let base: CGFloat
        let sway: CGFloat
        let period: Double
        let delay: Double
        let lag: Int
        let window: Int
        let gain: Double
    }

    /// Resting heights straight from the shot, tallest bar in the centre.
    private static let bars: [Bar] = [
        Bar(id: 0, base: 12, sway: 1.10, period: 1.20, delay: 0.00, lag: 5, window: 5, gain: 0.95),
        Bar(id: 1, base: 22, sway: 1.07, period: 0.78, delay: 0.35, lag: 3, window: 4, gain: 1.20),
        Bar(id: 2, base: 32, sway: 1.05, period: 1.60, delay: 0.15, lag: 1, window: 2, gain: 1.40),
        Bar(id: 3, base: 22, sway: 1.08, period: 0.92, delay: 0.55, lag: 3, window: 4, gain: 1.10),
        Bar(id: 4, base: 12, sway: 1.11, period: 0.66, delay: 0.25, lag: 6, window: 5, gain: 0.85),
    ]

    @State private var swaying = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Self.bars) { bar in
                let height = height(of: bar)
                Capsule()
                    .fill(color)
                    .frame(width: 5, height: height)
                    // The level moves the bar's real height, eased so the
                    // sixteen samples a second arrive as motion, not as steps.
                    .animation(.easeOut(duration: 0.16), value: height)
                    // The sway is a scale, so it never touches layout, and it
                    // reverses rather than restarting — nothing to jump at.
                    .scaleEffect(y: swaying ? bar.sway : 1 / bar.sway, anchor: .center)
                    .animation(
                        .easeInOut(duration: bar.period)
                            .repeatForever(autoreverses: true)
                            .delay(bar.delay),
                        value: swaying
                    )
            }
        }
        .onAppear { swaying = true }
        .accessibilityHidden(true)
    }

    private func height(of bar: Bar) -> CGFloat {
        max(5, bar.base * (1 + CGFloat(level(lag: bar.lag, window: bar.window) * bar.gain * 0.85)))
    }

    /// The room's loudness `lag` samples ago, averaged over `window` of them.
    /// A different window per bar is why they settle raggedly rather than
    /// together. Levels arrive about sixteen times a second, so six samples is a
    /// bit over a third of a second behind.
    private func level(lag: Int, window: Int) -> Double {
        guard model.phase == .recording else { return 0 }
        let levels = model.micLevels
        let end = levels.count - lag
        let start = max(0, end - window)
        guard end > start else { return 0 }
        let slice = levels[start ..< end]
        return min(1, Double(slice.reduce(0, +)) / Double(slice.count) * 1.7)
    }
}

/// A circle with its radius bent by two sine waves. Moving `phase` walks the
/// bulges around the rim, which is what makes it look alive rather than spun.
struct Blob: Shape {
    var phase: Double
    var wobble: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let steps = 14

        let points: [CGPoint] = (0 ..< steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            let bend = sin(angle * 3 + phase) * wobble + cos(angle * 5 - phase * 1.3) * wobble * 0.5
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
