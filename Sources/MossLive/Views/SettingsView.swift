import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
