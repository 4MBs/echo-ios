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

                TimetableSettingsSection()

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

/// WebUntis login + Tier-4 toggles. Credentials are sent to the Fedora server
/// (which stores and uses them) — never kept on the phone.
struct TimetableSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var school = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var ok = false
    @State private var message: String?

    var body: some View {
        Section {
            TextField("Schule (z. B. avs-itzehoe)", text: $school)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Benutzername", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Passwort", text: $password)
            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView() }
                    Text(busy ? "Verbinde…" : "Mit WebUntis verbinden")
                }
            }
            .disabled(busy || school.isEmpty || username.isEmpty || password.isEmpty)
            if let message {
                Text(message).font(.caption).foregroundStyle(ok ? .green : .red)
            }

            Toggle("Erinnerung bei Stundenbeginn", isOn: notificationsBinding)
            Toggle("Aufnahme bei Stundenende stoppen", isOn: autoStopBinding)
        } header: {
            Text("Stundenplan (WebUntis)")
        } footer: {
            Text(footerText)
        }
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.lessonNotifications },
            set: { value in
                model.settings.lessonNotifications = value
                Task { await model.syncTimetableNotifications() }
            }
        )
    }

    private var autoStopBinding: Binding<Bool> {
        Binding(
            get: { model.settings.autoStopAtLessonEnd },
            set: { model.settings.autoStopAtLessonEnd = $0 }
        )
    }

    private var footerText: String {
        if model.timetable.enabled {
            if let current = model.timetable.current {
                return "Verbunden · aktuell: \(current.title)"
            }
            return "Verbunden. Aufnahmen werden automatisch dem Fach zugeordnet."
        }
        return "Melde dich an, damit Aufnahmen automatisch dem richtigen Fach "
            + "zugeordnet werden. Dein Passwort wird nur auf deinem eigenen Server gespeichert."
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
            message = "Verbunden."
            password = ""
            await model.refreshTimetable()
            await model.syncTimetableNotifications()
        } catch {
            ok = false
            message = error.localizedDescription
        }
    }
}
