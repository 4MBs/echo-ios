import SwiftUI

/// The dictation control shared by every AI composer. Recording feedback is
/// drawn entirely inside a stable 38-point box, so starting or stopping the
/// microphone cannot participate in the surrounding row's layout.
struct ComposerVoiceButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.16))
                    .frame(width: 34, height: 34)
                    .scaleEffect(isRecording ? 1 : 0.72)
                    .opacity(isRecording ? 1 : 0)

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(isRecording ? .red : .secondary)
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isRecording)
        }
        .buttonStyle(ComposerControlButtonStyle())
        .accessibilityLabel(isRecording ? "Diktat beenden" : "Frage diktieren")
    }
}

/// Press feedback stays inside the control's fixed frame rather than changing
/// the size SwiftUI offers to the composer row.
struct ComposerControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.14),
                value: configuration.isPressed
            )
    }
}
