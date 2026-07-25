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

/// The record control: a soft blob under a red gradient, with two paler blobs
/// drifting behind it and a waveform cut into the middle.
///
/// Modelled on Don Pardon's "Record Button (Voice Messanger App)", down to its
/// palette. Nothing here is an image — the blob is a circle whose radius is bent
/// by two sine waves, so it can be animated by moving their phase, and it stays
/// sharp at any size.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    // straight from the shot's palette
    private static let vivid = Color(red: 254 / 255, green: 22 / 255, blue: 14 / 255)
    private static let coral = Color(red: 253 / 255, green: 88 / 255, blue: 81 / 255)
    private static let deep = Color(red: 154 / 255, green: 11 / 255, blue: 7 / 255)
    private static let pale = Color(red: 244 / 255, green: 169 / 255, blue: 162 / 255)

    /// The waveform in the middle of the shot, tallest bar in the centre.
    private static let glyphBars: [CGFloat] = [12, 22, 32, 22, 12]

    @State private var phase: Double = 0

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
            ZStack {
                halo
                Blob(phase: phase, wobble: isActive ? 0.09 : 0.055)
                    .fill(
                        LinearGradient(
                            colors: [Self.vivid, Self.coral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 78, height: 78)
                    .shadow(color: Self.vivid.opacity(0.45), radius: 16, y: 6)
                glyph
            }
            .frame(width: 108, height: 108)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isActive)
        .sensoryFeedback(.impact(weight: .medium), trigger: isActive)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
        .onAppear {
            // one slow rotation of the phase, forever: the blob never settles
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }

    /// Two paler blobs, larger and slower, turning the wrong way — the halo in
    /// the shot, and the only thing moving on the screen at rest.
    private var halo: some View {
        ZStack {
            Blob(phase: -phase * 0.8 + 1.4, wobble: 0.07)
                .fill(Self.pale.opacity(isActive ? 0.34 : 0.22))
                .frame(width: 102, height: 102)
                .blur(radius: 3)
            Blob(phase: phase * 0.55 + 3.1, wobble: 0.08)
                .fill(Self.pale.opacity(isActive ? 0.26 : 0.16))
                .frame(width: 92, height: 92)
                .blur(radius: 2)
        }
    }

    /// The waveform from the shot at rest; a stop square once running, because
    /// the control has to say what pressing it will do.
    @ViewBuilder
    private var glyph: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Self.deep.opacity(0.85))
                .frame(width: 24, height: 24)
                .transition(.scale.combined(with: .opacity))
        } else {
            HStack(alignment: .center, spacing: 4) {
                // indices, not the heights themselves: the shape is symmetric,
                // so the values repeat and would collide as identities
                ForEach(Self.glyphBars.indices, id: \.self) { index in
                    Capsule()
                        .fill(Self.deep.opacity(0.85))
                        .frame(width: 5, height: Self.glyphBars[index])
                }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// A circle with its radius bent by two sine waves. Moving `phase` walks the
/// bulges around the rim, which is what makes it look alive rather than spun.
struct Blob: Shape {
    var phase: Double
    var wobble: Double

    /// Both are animated, so a press can deepen the wobble while it turns.
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, wobble) }
        set {
            phase = newValue.first
            wobble = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let steps = 14

        let points: [CGPoint] = (0 ..< steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            let bend = sin(angle * 3 + phase) * wobble + cos(angle * 5 - phase * 1.3) * wobble * 0.5
            let distance = radius * (1 - wobble + bend)
            return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        }

        // Quad curves between the midpoints, with each sample as the control
        // point: a closed curve with no corners anywhere.
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
