import SwiftUI

/// The live workspace keeps recording as the single primary action. Transcript
/// and assistant content sit beneath it instead of competing as four equal cards.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize

    private var isWide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            ZStack {
                MossBackground()
                VStack(spacing: 12) {
                    liveHeader
                    if let banner = model.bannerMessage {
                        BannerView(text: banner)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if model.timetable.enabled {
                        CurrentLessonBanner()
                    }
                    if isWide {
                        wideBody
                    } else {
                        compactBody
                    }
                }
                .padding(16)
                .animation(.snappy, value: model.bannerMessage)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var liveHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MOSS / LIVE").font(.caption.weight(.black)).tracking(2.4).foregroundStyle(MossTheme.accent)
                Text("Listening room").font(.largeTitle.weight(.black))
            }
            Spacer()
            StatusPill()
        }
    }

    private var wideBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 14) {
                RecordingHero()
                TranscriptCard().frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 14) {
                AIAssistantCard().frame(maxHeight: .infinity)
                AnswerButton()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var compactBody: some View {
        VStack(spacing: 14) {
            RecordingHero()
            TranscriptCard().frame(maxHeight: .infinity)
            AIAssistantCard()
            AnswerButton()
        }
    }
}

/// A quiet backdrop so the glass panels read; adaptive for light/dark.
struct LiveBackground: View {
    var body: some View {
        MossBackground()
    }
}

/// Tier 2: the lesson happening now (or the next one). Informational — not a
/// button (no navigation).
struct CurrentLessonBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.teal)
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MossTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(MossTheme.accent.opacity(0.18)) }
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
        var parts = ["\(lesson.start)–\(lesson.end)"]
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

struct StatusPill: View {
    @Environment(AppModel.self) private var model

    private var isBusy: Bool {
        model.phase == .connecting || model.phase == .reconnecting
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.phase.color)
                .frame(width: 8, height: 8)
                .opacity(isBusy ? 0.35 : 1)
                .animation(
                    isBusy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                    value: isBusy
                )
            Text(statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(model.phase == .disconnected ? .secondary : .primary)
                .lineLimit(1)
            if let rtt = model.lastRoundTripMs,
               model.phase == .recording || model.phase == .connected {
                Text("· \(Int(rtt)) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(MossTheme.raisedSurface, in: Capsule())
    }

    private var statusText: String {
        if case .error(let message) = model.phase {
            return message
        }
        return model.phase.label
    }
}

struct RecordingTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.red.opacity(0.12), in: Capsule())
        }
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MossTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Recording hero

struct RecordingHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke((model.phase == .recording ? Color.red : MossTheme.accent).opacity(0.12), lineWidth: 18)
                    .frame(width: 116, height: 116)
                RecordButton()
            }
            VStack(spacing: 6) {
                Text(model.phase == .recording ? "Recording in progress" : "Ready when you are")
                    .font(.title3.weight(.bold))
                Text(
                    model.phase == .recording
                        ? "Audio is streaming securely to Fedora."
                        : "Tap once to begin the live transcript."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if model.phase == .recording, let started = model.recordingStartedAt {
                    RecordingTimer(startedAt: started)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 24)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(MossTheme.surface, in: RoundedRectangle(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(model.phase == .recording ? Color.red.opacity(0.28) : Color.primary.opacity(0.06))
        }
    }
}

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
            Image(systemName: isActive ? "stop.fill" : "mic.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 82, height: 82)
                .background(isActive ? Color.red : MossTheme.accent, in: Circle())
                .shadow(color: (isActive ? Color.red : MossTheme.accent).opacity(0.25), radius: 14, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Stop recording" : "Start recording")
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
}
