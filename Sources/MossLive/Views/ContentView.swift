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
        // The control carries its own margin — its layers and their blur need
        // room inside its frame — so the dock adds little of its own.
        .padding(.top, isRecording ? 8 : 12)
        .padding(.bottom, 4)
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

/// The record control: an inflated rounded square blended with a circle, under a
/// luminous gradient, with five translucent duplicates offset around it and a
/// five-bar waveform at the centre. Modelled on Don Pardon's "Record Button
/// (Voice Messanger App)" and tuned against a live preview of this same maths.
///
/// Two things make it read as liquid rather than as a spinning graphic. Every
/// layer moves on its own clock — its own outline, drift, rotation, breathing
/// period and offset — so the overlaps slide across each other instead of
/// travelling together. And every layer hears the microphone at its own delay,
/// so a loud syllable sweeps outwards through them rather than inflating the
/// whole control at once.
///
/// The whole thing is drawn in one Metal pass with a single blur. The obvious
/// way to build it — a blur on each of the five layers, and the middle masked
/// and blurred again — costs eight offscreen passes a frame, which is what made
/// it stutter.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    /// Everything is a multiple of this, so the control scales as one piece.
    private static let coreRadius: CGFloat = 39
    private static let extent: CGFloat = 136
    /// The drift, spin and breathing are all slow, and the microphone only
    /// reports sixteen times a second, so thirty frames carries it. Steady
    /// frames at thirty read as smoother than sixty with drops.
    private static let frameRate = 30.0

    // MARK: the layers

    /// One translucent duplicate. Nothing here is shared with its neighbours.
    private struct Layer: Identifiable {
        let id: Int
        let skeleton: [Blob.Harmonic]
        /// The outline's silhouette, sampled once at build time rather than
        /// recomputed from powers on every frame.
        let profile: [Double]
        let scale: CGFloat
        /// Hue, saturation and brightness rather than a colour: the tint setting
        /// rotates the whole family at once and they keep their relationships.
        let hue: Double
        let saturation: Double
        let brightness: Double
        let opacity: Double
        /// Speed and direction the outline morphs at.
        let drift: Double
        /// Radians per second the silhouette turns; this is what slides the
        /// overlaps across each other.
        let spin: Double
        let breathRate: Double
        let breathPhase: Double
        let offset: CGSize
        /// Microphone samples behind the core, and how much level it takes up.
        let lag: Int
        let response: Double
    }

    private static let layers: [Layer] = [
        Layer(
            id: 0, skeleton: Blob.skeleton(seed: 7), profile: Blob.profile(squareness: 0.50),
            scale: 1.16, hue: 0.0247, saturation: 0.263, brightness: 1, opacity: 0.15,
            drift: -0.50, spin: 0.07, breathRate: 0.31, breathPhase: 0.0,
            offset: CGSize(width: -0.048, height: -0.238), lag: 10, response: 0.20
        ),
        Layer(
            id: 1, skeleton: Blob.skeleton(seed: 23), profile: Blob.profile(squareness: 0.56),
            scale: 1.12, hue: 0.0227, saturation: 0.404, brightness: 1, opacity: 0.17,
            drift: 0.70, spin: -0.11, breathRate: 0.23, breathPhase: 1.9,
            offset: CGSize(width: 0.238, height: 0.095), lag: 7, response: 0.17
        ),
        Layer(
            id: 2, skeleton: Blob.skeleton(seed: 61), profile: Blob.profile(squareness: 0.60),
            scale: 1.10, hue: 0.0203, saturation: 0.576, brightness: 1, opacity: 0.19,
            drift: -0.95, spin: 0.15, breathRate: 0.41, breathPhase: 3.4,
            offset: CGSize(width: -0.226, height: 0.131), lag: 5, response: 0.14
        ),
        Layer(
            id: 3, skeleton: Blob.skeleton(seed: 97), profile: Blob.profile(squareness: 0.64),
            scale: 1.07, hue: 0.0170, saturation: 0.686, brightness: 1, opacity: 0.21,
            drift: 1.20, spin: -0.09, breathRate: 0.27, breathPhase: 5.0,
            offset: CGSize(width: 0.107, height: 0.226), lag: 3, response: 0.11
        ),
        Layer(
            id: 4, skeleton: Blob.skeleton(seed: 131), profile: Blob.profile(squareness: 0.66),
            scale: 1.04, hue: 0.0142, saturation: 0.741, brightness: 1, opacity: 0.22,
            drift: -1.45, spin: 0.19, breathRate: 0.35, breathPhase: 2.4,
            offset: CGSize(width: -0.119, height: -0.107), lag: 2, response: 0.08
        ),
    ]

    private static let coreProfile = Blob.profile(squareness: 0.62)

    // MARK: the waveform

    /// One bar. Four of these differ per bar — clock, delay, gain, smoothing —
    /// which is what stops the five of them moving as one object.
    private struct Bar: Identifiable {
        let id: Int
        let base: CGFloat
        let frequency: Double
        let phase: Double
        /// Samples behind now: the middle bar hears the room almost live, the
        /// outer pair a third of a second late.
        let lag: Int
        /// Samples averaged, which is this bar's smoothing.
        let window: Int
        let gain: Double
    }

    private static let bars: [Bar] = [
        Bar(id: 0, base: 0.34, frequency: 0.83, phase: 0.0, lag: 5, window: 5, gain: 0.95),
        Bar(id: 1, base: 0.63, frequency: 1.27, phase: 1.7, lag: 3, window: 4, gain: 1.20),
        Bar(id: 2, base: 1.00, frequency: 0.61, phase: 3.1, lag: 1, window: 2, gain: 1.40),
        Bar(id: 3, base: 0.63, frequency: 1.09, phase: 4.4, lag: 3, window: 4, gain: 1.10),
        Bar(id: 4, base: 0.34, frequency: 1.51, phase: 5.6, lag: 6, window: 5, gain: 0.85),
    ]

    private var isActive: Bool {
        switch model.phase {
        case .recording, .connecting, .reconnecting, .connected: true
        default: false
        }
    }

    /// Rotates every colour in the control together, from Einstellungen.
    private var shift: Double { model.settings.recordButtonHue }

    private func tint(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
        Color(
            hue: (hue + shift).truncatingRemainder(dividingBy: 1),
            saturation: saturation,
            brightness: brightness
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
            // A timeline, not a repeating animation: the phase is read from the
            // clock every frame, so nothing ever restarts or jumps.
            TimelineView(.animation(minimumInterval: 1.0 / Self.frameRate)) { context in
                content(at: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: Self.extent, height: Self.extent)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isActive)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }

    private func content(at time: TimeInterval) -> some View {
        ZStack {
            halo(at: time)
            interior(at: time)
            waveform(at: time)
        }
        // One rasterisation for the lot, on the GPU. Without it every layer's
        // blur and blend is its own pass through Core Animation.
        .drawingGroup()
    }

    /// The five duplicates, blurred once as a group rather than five times.
    private func halo(at time: TimeInterval) -> some View {
        ZStack {
            ForEach(Self.layers) { layer in
                let heard = level(lag: layer.lag, window: 4)
                let breathe = 1 + 0.022 * sin(time * layer.breathRate * 2 + layer.breathPhase)
                let side = Self.coreRadius * 2 * layer.scale * CGFloat(breathe)
                    * (1 + CGFloat(heard) * 0.045) * Blob.margin

                Blob(
                    harmonics: layer.skeleton,
                    profile: layer.profile,
                    time: time,
                    drift: layer.drift,
                    swell: 1 + heard * layer.response
                )
                .fill(tint(layer.hue, layer.saturation, layer.brightness))
                .frame(width: side, height: side)
                // Turning the finished shape is free; baking the angle into the
                // path means recomputing every point's position instead.
                .rotationEffect(.radians(time * layer.spin))
                .offset(
                    x: layer.offset.width * Self.coreRadius,
                    y: layer.offset.height * Self.coreRadius
                )
                .opacity(layer.opacity)
                // On white the artwork's pale layers stay pale; on black the
                // same fill at the same opacity turns brown. They have to add
                // light instead of veiling it.
                .blendMode(.plusLighter)
            }
        }
        .blur(radius: 1.6)
    }

    /// The saturated middle: a gradient across it for the tonal variation, and a
    /// highlight off-centre for depth. Two fills of one shape — a mask would be
    /// another offscreen pass for the same picture.
    private func interior(at time: TimeInterval) -> some View {
        let core = level(lag: 0, window: 3)
        let side = Self.coreRadius * 2 * (1 + CGFloat(core) * 0.03) * Blob.margin
        let shape = Blob(
            harmonics: Blob.base,
            profile: Self.coreProfile,
            time: time,
            swell: 1 + core * 0.3
        )

        return ZStack {
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: tint(0.0098, 0.867, 1), location: 0),
                        .init(color: tint(0.0163, 0.800, 1), location: 0.5),
                        .init(color: tint(0.0341, 0.729, 1), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.fill(
                RadialGradient(
                    stops: [
                        .init(color: tint(0.0379, 0.624, 1).opacity(0.42), location: 0),
                        .init(color: tint(0.0163, 0.800, 1).opacity(0.12), location: 0.6),
                        .init(color: tint(0.0098, 0.878, 1).opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.35, y: 0.34),
                    startRadius: Self.coreRadius * 0.08,
                    endRadius: Self.coreRadius * 1.05
                )
            )
        }
        .frame(width: side, height: side)
    }

    private func waveform(at time: TimeInterval) -> some View {
        let width = Self.coreRadius * 0.16
        let tallest = Self.coreRadius * 0.80

        return HStack(alignment: .center, spacing: Self.coreRadius * 0.10) {
            ForEach(Self.bars) { bar in
                Capsule()
                    .fill(tint(0.0098, 0.945, 0.502).opacity(0.5))
                    .frame(width: width, height: height(of: bar, at: time, tallest: tallest))
            }
        }
    }

    /// Idle, every bar drifts on its own frequency and phase, so they are never
    /// in step even in silence. Recording, each adds its own slice of the level
    /// history at its own gain, so a loud moment changes the shape of the
    /// waveform rather than just its size.
    private func height(of bar: Bar, at time: TimeInterval, tallest: CGFloat) -> CGFloat {
        let idle = 1 + 0.085 * sin(time * bar.frequency * 1.6 + bar.phase)
        let live = 1 + level(lag: bar.lag, window: bar.window) * bar.gain * 0.85
        return max(Self.coreRadius * 0.16, tallest * bar.base * CGFloat(idle * live))
    }

    /// The room's loudness `lag` samples ago, averaged over `window` of them.
    /// Averaging is the smoothing, and a different window per bar is why they
    /// settle raggedly instead of together. Levels arrive about sixteen times a
    /// second, so ten samples is a little over half a second behind.
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

/// The silhouette: a superellipse blended with a circle, then bent by four
/// harmonics.
///
/// Only four. The artwork's own outline has seven, but orders five and up are
/// small ripples — at button size they read as scalloping, and dropping them is
/// what leaves broad shoulders and a gently irregular top. With no frequency
/// above the fourth present, the outline cannot grow a pointed bulge or a deep
/// indentation however hard it is pushed.
struct Blob: Shape {
    struct Harmonic {
        let amplitude: Double
        let phase: Double
    }

    /// Room left around the outline inside its frame, so a bulge never clips.
    static let margin: CGFloat = 1.25
    static let steps = 80

    static let base: [Harmonic] = [
        Harmonic(amplitude: 0.010, phase: -2.32),
        Harmonic(amplitude: 0.045, phase: -1.74),
        Harmonic(amplitude: 0.030, phase: -2.64),
        Harmonic(amplitude: 0.018, phase: -3.00),
    ]

    /// Unit direction per sample. Fixed, so the sines and cosines that place the
    /// points are paid for once for the life of the app rather than every frame.
    static let directions: [CGPoint] = (0 ..< steps).map { step in
        let angle = Double(step) / Double(steps) * 2 * .pi
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    /// The silhouette itself, sampled: a superellipse blended towards a circle,
    /// `width` wider than tall. Two powers and a root per sample, so it is built
    /// once per distinct squareness rather than 80 times a frame.
    static func profile(squareness: Double, width: Double = 1.12, power: Double = 3.8) -> [Double] {
        (0 ..< steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            let superellipse = 1 / pow(
                pow(abs(cos(angle) / width), power) + pow(abs(sin(angle)), power),
                1 / power
            )
            return (1 - squareness) + superellipse * squareness
        }
    }

    /// A sibling outline: the same family of amplitudes, its own phases.
    /// Deterministic, so a layer keeps its shape between frames.
    static func skeleton(seed: UInt64) -> [Harmonic] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 10_000) / 10_000
        }
        return base.map { harmonic in
            Harmonic(amplitude: harmonic.amplitude * (0.75 + next() * 0.5), phase: next() * 2 * .pi)
        }
    }

    var harmonics: [Harmonic]
    var profile: [Double]
    var time: Double
    var drift: Double = 1
    var swell: Double = 1

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 / Self.margin
        let steps = Self.steps
        let step = 2 * Double.pi / Double(steps)

        let points: [CGPoint] = (0 ..< steps).map { index in
            let angle = Double(index) * step
            var bend = 0.0
            for (order, harmonic) in harmonics.enumerated() {
                let multiple = Double(order + 1)
                let turn = time * drift * (0.19 + 0.05 * multiple)
                bend += harmonic.amplitude * swell * cos(multiple * angle + harmonic.phase + turn)
            }
            let silhouette = index < profile.count ? profile[index] : 1
            let distance = radius * CGFloat(silhouette * (1 + bend))
            let direction = Self.directions[index]
            return CGPoint(x: center.x + direction.x * distance, y: center.y + direction.y * distance)
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
