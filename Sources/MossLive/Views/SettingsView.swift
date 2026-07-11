import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    TextField("100.92.57.51 or fedora", text: $settings.serverHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    SecureField("Auth token", text: $settings.authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Fedora server (Tailscale)")
                } footer: {
                    Text(
                        """
                        On the server: address = `tailscale ip -4`, \
                        token = the MOSSLIVE_AUTH_TOKEN value in ~/.config/mosslive/env. \
                        Both devices must be on the same tailnet.
                        """
                    )
                }

                Section("AI answer") {
                    Stepper(value: $settings.contextSeconds, in: 10 ... 120, step: 5) {
                        Text("Context window: \(Int(settings.contextSeconds)) s")
                    }
                }

                Section {
                    Picker("Audio bitrate", selection: $settings.bitrate) {
                        Text("16 kbps (lowest data)").tag(16000)
                        Text("24 kbps (recommended)").tag(24000)
                        Text("32 kbps").tag(32000)
                    }
                } footer: {
                    Text("24 kbps ≈ 11 MiB per hour of streaming.")
                }

                Section {
                    LabeledContent("Transcription", value: "Qwen3-ASR 1.7B")
                    LabeledContent("Answers", value: "Gemini 3.5 Flash")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Widget link", value: SharedConfig.resolvedGroupID ?? "unavailable")
                        .font(.footnote)
                } header: {
                    Text("About")
                } footer: {
                    Text(
                        """
                        Audio is processed only on your own server; nothing goes to third \
                        parties except the transcript excerpt sent to Gemini when you \
                        request an answer.
                        """
                    )
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
