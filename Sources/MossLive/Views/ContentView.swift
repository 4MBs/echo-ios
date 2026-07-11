import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showLessons = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 14) {
                HeaderBar(showSettings: $showSettings, showLessons: $showLessons)
                if let banner = model.bannerMessage {
                    BannerView(text: banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                TranscriptCard()
                AnswerCard()
                ControlBar()
            }
            .padding(16)
            .animation(.snappy, value: model.bannerMessage)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showLessons) {
            LessonsView()
        }
        .onAppear {
            if !model.settings.isConfigured {
                showSettings = true
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Subtle depth instead of a flat black sheet.
struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.07, green: 0.07, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Header

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showLessons: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MOSS Live")
                    .font(.title2.weight(.bold))
                StatusPill()
            }
            Spacer()
            if model.phase == .recording, let started = model.recordingStartedAt {
                RecordingTimer(startedAt: started)
            }
            Button {
                showLessons = true
            } label: {
                Image(systemName: "books.vertical.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 40, height: 40)
                    .background(.purple.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Lessons")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
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
                .lineLimit(2)
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
            .padding(.vertical, 8)
            .background(.red.opacity(0.12), in: Capsule())
        }
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.yellow)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
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
    ContentView()
        .environment(AppModel())
}
