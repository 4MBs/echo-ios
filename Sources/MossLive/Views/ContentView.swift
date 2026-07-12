import SwiftUI

/// The Live tab. On iPad (regular width) it's a two-column layout — live
/// transcript on the left, AI assistant on the right — with the record control
/// under the transcript (left) and the answer control under the assistant
/// (right). On iPhone it stacks. Styled with iOS 26 Liquid Glass.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize

    private var isWide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 14) {
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
            .background(LiveBackground())
            .navigationTitle("MOSS Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatusPill() }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.phase == .recording, let started = model.recordingStartedAt {
                        RecordingTimer(startedAt: started)
                    }
                }
            }
        }
    }

    // Left column controls the transcript; right column controls the assistant.
    private var wideBody: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                TranscriptCard().frame(maxWidth: .infinity)
                AIAssistantCard().frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                RecordButton().frame(maxWidth: .infinity)
                AnswerButton().frame(maxWidth: .infinity)
            }
        }
    }

    private var compactBody: some View {
        VStack(spacing: 14) {
            TranscriptCard().frame(maxHeight: .infinity)
            AIAssistantCard()
            RecordButton()
            AnswerButton()
        }
    }
}

/// A quiet backdrop so the glass panels read; adaptive for light/dark.
struct LiveBackground: View {
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
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
        .glassEffect(.regular.tint(.teal.opacity(0.18)), in: .rect(cornerRadius: 18))
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
        .glassEffect(.regular.tint(model.phase.color.opacity(0.22)), in: .capsule)
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
            .glassEffect(.regular.tint(.red.opacity(0.22)), in: .capsule)
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
            .glassEffect(.regular.tint(.orange.opacity(0.2)), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Record control (left, under the transcript)

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
            HStack(spacing: 14) {
                Image(systemName: isActive ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isActive ? "Stop Recording" : "Start Recording")
                        .font(.headline)
                    Text("Live-Transkript erfassen")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glassProminent)
        .tint(isActive ? .red : .teal)
        .buttonBorderShape(.roundedRectangle(radius: 22))
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
}
