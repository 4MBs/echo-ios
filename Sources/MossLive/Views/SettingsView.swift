import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    TextField("100.92.57.51 oder fedora", text: $settings.serverHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    SecureField("Auth-Token", text: $settings.authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Fedora-Server (Tailscale)")
                } footer: {
                    Text(
                        """
                        Auf dem Server: Adresse = `tailscale ip -4`, \
                        Token = der Wert MOSSLIVE_AUTH_TOKEN in ~/.config/mosslive/env. \
                        Beide Geräte müssen im selben Tailnet sein.
                        """
                    )
                }

                Section {
                    Picker("App", selection: $settings.quickSwitchURL) {
                        Text("GoodNotes").tag("goodnotes://")
                        Text("Notizen").tag("mobilenotes://")
                        Text("Safari").tag("https://www.google.com")
                        Text("Bücher").tag("ibooks://")
                    }
                    TextField("Eigenes URL-Schema (z. B. goodnotes://)", text: $settings.quickSwitchURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                } header: {
                    Text("Schneller App-Wechsel")
                } footer: {
                    Text(
                        "Tippe irgendwo in der App mit drei Fingern gleichzeitig, um sofort in "
                            + "diese App zu wechseln. Die Aufnahme läuft im Hintergrund weiter."
                    )
                }

                TimetableSettingsSection()

                Section {
                    Stepper(value: $settings.contextSeconds, in: 10 ... 120, step: 5) {
                        Text("Kontextfenster: \(Int(settings.contextSeconds)) s")
                    }
                } header: {
                    Text("Widget-Antwort")
                } footer: {
                    Text(
                        "Wie viele Sekunden Transkript ein Tipp auf das Widget an die KI schickt. "
                            + "Die Antwort erscheint nur im Widget."
                    )
                }

                Section {
                    Picker("Audio-Bitrate", selection: $settings.bitrate) {
                        Text("16 kbit/s (wenigste Daten)").tag(16000)
                        Text("24 kbit/s (empfohlen)").tag(24000)
                        Text("32 kbit/s").tag(32000)
                    }
                } footer: {
                    Text("24 kbit/s ≈ 11 MiB pro Stunde Streaming.")
                }

                Section {
                    LabeledContent("Transkription", value: "Qwen3-ASR 1.7B")
                    LabeledContent("Antworten", value: "Gemini 3.5 Flash")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Widget-Verbindung", value: SharedConfig.resolvedGroupID ?? "nicht verfügbar")
                        .font(.footnote)
                } header: {
                    Text("Über")
                } footer: {
                    Text(
                        """
                        Audio wird nur auf deinem eigenen Server verarbeitet; nichts geht an \
                        Dritte, außer dem Transkript-Ausschnitt, der bei einer KI-Anfrage an \
                        Gemini geschickt wird.
                        """
                    )
                }
            }
            .navigationTitle("Einstellungen")
            .task { await model.refreshTimetable() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// WebUntis login + Tier-4 toggles. Credentials are sent to the Fedora server
/// (which stores and uses them) — they never live on the iPad, so once the
/// server is connected this shows a clear "logged in" state instead of empty
/// fields; re-login hides behind "Anmeldung ändern".
struct TimetableSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var school = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var ok = false
    @State private var message: String?
    @State private var editingLogin = false

    private var isConnected: Bool { model.timetable.enabled }

    var body: some View {
        Section {
            if isConnected {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mit WebUntis verbunden")
                            .font(.body.weight(.semibold))
                        Text(connectedSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !isConnected || editingLogin {
                loginFields
            } else {
                Button("Anmeldung ändern") { editingLogin = true }
            }
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

    @ViewBuilder
    private var loginFields: some View {
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
    }

    private var connectedSubtitle: String {
        if let current = model.timetable.current {
            return "Aktuell: \(current.title)"
        }
        if let next = model.timetable.next {
            return "Als Nächstes: \(next.title) · \(next.start)"
        }
        return "Stundenplan wird vom Server abgerufen."
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
        if isConnected {
            return "Aufnahmen werden automatisch dem richtigen Fach zugeordnet. "
                + "Deine Zugangsdaten sind nur auf deinem eigenen Server gespeichert."
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
            editingLogin = false
            await model.refreshTimetable()
            await model.syncTimetableNotifications()
        } catch {
            ok = false
            message = error.localizedDescription
        }
    }
}
