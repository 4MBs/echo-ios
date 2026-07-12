import SwiftUI

/// The Live tab: connection status, live transcript, AI answer, and the
/// record controls — laid out as a standard navigation screen so the app
/// follows platform conventions (system backgrounds, light/dark adaptive).
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let banner = model.bannerMessage {
                    BannerView(text: banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.timetable.enabled {
                    CurrentLessonBanner()
                }
                TranscriptCard()
                AnswerCard()
                ControlBar()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .animation(.snappy, value: model.bannerMessage)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MOSS Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusPill()
                }
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
                .foregroundStyle(.teal)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
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
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(model.phase.color.opacity(0.12), in: Capsule())
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
            .padding(.vertical, 6)
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
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Controls

struct ControlBar: View {
    var body: some View {
        VStack(spacing: 10) {
            AnswerButton()
            RecordButton()
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
            Label(
                isActive ? "Stop Recording" : "Start Recording",
                systemImage: isActive ? "stop.fill" : "record.circle"
            )
            .font(.body.weight(.semibold))
            .foregroundStyle(isActive ? .red : .green)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                (isActive ? Color.red : Color.green).opacity(0.13),
                in: RoundedRectangle(cornerRadius: 15)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainTabView()
        .environment(AppModel())
}
