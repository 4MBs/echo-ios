import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                StatusHeader()
                if let banner = model.bannerMessage {
                    BannerView(text: banner)
                }
                TranscriptView()
                AnswerCard()
                AnswerButton()
                RecordButton()
            }
            .padding()
            .navigationTitle("MOSS Live")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                if !model.settings.isConfigured {
                    showSettings = true
                }
            }
        }
    }
}

struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.phase.color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Spacer()
            if model.isTranscribing {
                Label("Transcribing", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
            if let rtt = model.lastRoundTripMs {
                Text("\(Int(rtt)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusText: String {
        if case .error(let message) = model.phase {
            return message
        }
        return model.phase.label
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    private var isActive: Bool {
        switch model.phase {
        case .recording, .connecting, .reconnecting, .connected: return true
        default: return false
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
                isActive ? "Stop" : "Start Recording",
                systemImage: isActive ? "stop.circle.fill" : "record.circle"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .red : .green)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
