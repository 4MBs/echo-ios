import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MossCard {
                        VStack(alignment: .leading, spacing: 14) {
                            MossSectionHeader(
                                "Your Fedora server",
                                subtitle: "Private connection over Tailscale",
                                symbol: "server.rack"
                            )
                            TextField("100.92.57.51 or fedora", text: $settings.serverHost)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            SecureField("Auth token", text: $settings.authToken)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Text("Use `tailscale ip -4` for the address and MOSSLIVE_AUTH_TOKEN from your server.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    MossCard {
                        VStack(alignment: .leading, spacing: 16) {
                            MossSectionHeader("Session preferences", symbol: "slider.horizontal.3", tint: .purple)
                            Stepper(value: $settings.contextSeconds, in: 10 ... 120, step: 5) {
                                LabeledContent("AI context", value: "\(Int(settings.contextSeconds)) sec")
                            }
                            Divider()
                            Picker("Audio quality", selection: $settings.bitrate) {
                                Text("Data saver · 16 kbps").tag(16000)
                                Text("Balanced · 24 kbps").tag(24000)
                                Text("High · 32 kbps").tag(32000)
                            }
                            Text("Balanced uses roughly 11 MiB per hour.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    TimetableSettingsCard()

                    MossCard {
                        VStack(alignment: .leading, spacing: 12) {
                            MossSectionHeader("Privacy & app", symbol: "lock.shield", tint: .blue)
                            LabeledContent("Transcription", value: "Qwen3-ASR 1.7B")
                            LabeledContent("Answers", value: "Gemini 3.5 Flash")
                            LabeledContent("Version", value: appVersion)
                            Text(
                                "Audio stays on your server. Only an excerpt is sent to Gemini "
                                    + "when you explicitly ask for an answer."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .background(MossBackground())
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct TimetableSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var school = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var ok = false
    @State private var message: String?

    var body: some View {
        MossCard {
            VStack(alignment: .leading, spacing: 14) {
                MossSectionHeader(
                    "Timetable",
                    subtitle: model.timetable.enabled ? "Connected to WebUntis" : "Automatically label your recordings",
                    symbol: "calendar",
                    tint: .orange
                )
                TextField("School", text: $school)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                Button { Task { await connect() } } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(busy ? "Connecting…" : "Connect WebUntis").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).tint(.orange)
                .disabled(busy || school.isEmpty || username.isEmpty || password.isEmpty)
                if let message {
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(ok ? .green : .red)
                }
                Divider()
                Toggle("Lesson start reminders", isOn: notificationsBinding)
                Toggle("Stop recording when class ends", isOn: autoStopBinding)
                Text(footerText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(get: { model.settings.lessonNotifications }, set: { value in
            model.settings.lessonNotifications = value
            Task { await model.syncTimetableNotifications() }
        })
    }

    private var autoStopBinding: Binding<Bool> {
        Binding(
            get: { model.settings.autoStopAtLessonEnd },
            set: { model.settings.autoStopAtLessonEnd = $0 }
        )
    }

    private var footerText: String {
        if let current = model.timetable.current { return "Now: \(current.title)" }
        return model.timetable.enabled
            ? "Connected. Recordings are automatically matched to each class."
            : "Credentials are stored only on your own Fedora server."
    }

    private func connect() async {
        busy = true
        message = nil
        defer { busy = false }
        let api = BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
        do {
            try await api.submitWebUntisCredentials(school: school, username: username, password: password)
            ok = true
            message = "Connected"
            password = ""
            await model.refreshTimetable()
            await model.syncTimetableNotifications()
        } catch {
            ok = false
            message = error.localizedDescription
        }
    }
}
