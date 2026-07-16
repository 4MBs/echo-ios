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
                if model.phase == .recording {
                    RecordingWaveform()
                }
                RecordButton()
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

// MARK: - Controls

/// Decorative ink-purple waveform strip while recording (mockup style).
struct RecordingWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0 ..< 48, id: \.self) { bar in
                    let phase = time * 6 + Double(bar) * 0.9
                    let height = 6 + abs(sin(phase)) * 16 * (0.4 + 0.6 * abs(sin(Double(bar) * 1.7)))
                    Capsule()
                        .fill(Theme.accent.opacity(0.75))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 26)
        }
        .accessibilityHidden(true)
    }
}

/// The mockup's round record/stop control with its label next to it.
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
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.red : Theme.accent)
                        .frame(width: 52, height: 52)
                        .shadow(color: (isActive ? Color.red : Theme.accent).opacity(0.35), radius: 8, y: 3)
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(isActive ? "Aufnahme beenden" : "Aufnahme starten")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Aufnahme beenden" : "Aufnahme starten")
    }
}

#Preview {
    MainSplitView()
        .environment(AppModel())
}
