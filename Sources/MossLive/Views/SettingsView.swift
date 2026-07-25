import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Server",
                            subtitle: serverSubtitle,
                            systemImage: "server.rack",
                            color: .blue
                        )
                    }

                    NavigationLink {
                        TimetableSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "WebUntis",
                            subtitle: model.timetable.enabled ? "Verbunden" : "Nicht verbunden",
                            systemImage: "calendar",
                            color: .orange
                        )
                    }
                } header: {
                    Text("Verbindungen")
                }

                Section {
                    NavigationLink {
                        LearningSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Lernen",
                            subtitle: model.settings.learnReminderEnabled ? "Erinnerung ein" : "Erinnerung aus",
                            systemImage: "brain.head.profile",
                            color: .purple
                        )
                    }

                    NavigationLink {
                        QuickSwitchSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Schnellwechsel",
                            subtitle: quickSwitchName,
                            systemImage: "arrow.up.forward.app",
                            color: .green
                        )
                    }

                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Darstellung",
                            subtitle: RecordTint.nearest(to: model.settings.recordButtonHue).title,
                            systemImage: "paintpalette.fill",
                            color: .pink
                        )
                    }
                } header: {
                    Text("App")
                }

                Section {
                    NavigationLink {
                        AnswerSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "KI-Antworten",
                            subtitle: "\(Int(model.settings.contextSeconds)) Sekunden Kontext",
                            systemImage: "sparkles",
                            color: .indigo
                        )
                    }

                    NavigationLink {
                        AudioSettingsView()
                    } label: {
                        SettingsNavigationLabel(
                            title: "Audio",
                            subtitle: "\(model.settings.bitrate / 1000) kbit/s",
                            systemImage: "waveform",
                            color: .red
                        )
                    }
                } header: {
                    Text("Aufnahme")
                }

                Section {
                    LabeledContent("Transkription", value: "Qwen3-ASR 1.7B")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent(
                        "Widget",
                        value: SharedConfig.resolvedGroupID == nil ? "Nicht verfügbar" : "Bereit"
                    )
                } header: {
                    Text("Über Echo")
                } footer: {
                    Text("Audio bleibt auf deinem Server. Nur angefragte Textausschnitte gehen an die gewählte KI.")
                }
            }
            .navigationTitle("Einstellungen")
            .task { await model.refreshTimetable() }
        }
    }

    private var serverSubtitle: String {
        let host = model.settings.serverHost.trimmingCharacters(in: .whitespaces)
        return model.settings.isConfigured ? "\(host):\(model.settings.serverPort)" : "Nicht konfiguriert"
    }

    private var quickSwitchName: String {
        switch model.settings.quickSwitchURL {
        case "goodnotes5://": "GoodNotes"
        case "mobilenotes://": "Notizen"
        case "https://www.google.com": "Safari"
        case "ibooks://": "Bücher"
        default: "Eigene URL"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct SettingsNavigationLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: systemImage, color: color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                TextField("Adresse", text: $settings.serverHost, prompt: Text("fedora oder 100.64.0.1"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", value: $settings.serverPort, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                SecureField("Auth-Token", text: $settings.authToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Verbindung")
            } footer: {
                Text("Nutze die Tailscale-Adresse deines Servers. Beide Geräte müssen im selben Tailnet sein.")
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        settings.isConfigured ? "Konfiguriert" : "Unvollständig",
                        systemImage: settings.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(settings.isConfigured ? Color.green : Color.orange)
                }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TimetableSettingsView: View {
    var body: some View {
        Form {
            TimetableSettingsSection()
        }
        .navigationTitle("WebUntis")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct QuickSwitchSettingsView: View {
    @Environment(AppModel.self) private var model

    private static let presets = [
        "goodnotes5://", "mobilenotes://", "https://www.google.com", "ibooks://",
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("App", selection: $settings.quickSwitchURL) {
                    Text("GoodNotes").tag("goodnotes5://")
                    Text("Notizen").tag("mobilenotes://")
                    Text("Safari").tag("https://www.google.com")
                    Text("Bücher").tag("ibooks://")
                    if !Self.presets.contains(settings.quickSwitchURL) {
                        Text("Eigene URL").tag(settings.quickSwitchURL)
                    }
                }
            }

            Section {
                TextField("URL-Schema", text: $settings.quickSwitchURL, prompt: Text("goodnotes5://"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Ein Drei-Finger-Tipp öffnet diese App. Die Aufnahme läuft dabei weiter.")
            }
        }
        .navigationTitle("Schnellwechsel")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LearningSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Tägliche Erinnerung", isOn: reminderEnabledBinding(settings))
                if settings.learnReminderEnabled {
                    DatePicker(
                        "Uhrzeit",
                        selection: reminderTimeBinding(settings),
                        displayedComponents: .hourAndMinute
                    )
                }
            } footer: {
                Text("Erinnert dich an fällige Karten.")
            }
        }
        .navigationTitle("Lernen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reminderEnabledBinding(_ settings: AppSettings) -> Binding<Bool> {
        Binding(
            get: { settings.learnReminderEnabled },
            set: { value in
                settings.learnReminderEnabled = value
                Task { await LearnReminder.sync(enabled: value, minuteOfDay: settings.learnReminderMinutes) }
            }
        )
    }

    private func reminderTimeBinding(_ settings: AppSettings) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: settings.learnReminderMinutes / 60,
                    minute: settings.learnReminderMinutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.learnReminderMinutes = (comps.hour ?? 16) * 60 + (comps.minute ?? 0)
                Task {
                    await LearnReminder.sync(
                        enabled: settings.learnReminderEnabled,
                        minuteOfDay: settings.learnReminderMinutes
                    )
                }
            }
        )
    }
}

private struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                RecordTintPicker(hue: $settings.recordButtonHue)
            } header: {
                Text("Farbe des Aufnahmeknopfs")
            }

            Section {
                Toggle("Seitenzahlen anpassen", isOn: $settings.showPageNumberEditor)
            } header: {
                Text("Bibliothek")
            } footer: {
                Text("Blendet den Regler für gedruckte Seitenzahlen in Büchern ein.")
            }
        }
        .navigationTitle("Darstellung")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AnswerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Stepper(
                    "\(Int(settings.contextSeconds)) Sekunden",
                    value: $settings.contextSeconds,
                    in: 10 ... 120,
                    step: 5
                )
            } header: {
                Text("Kontext")
            } footer: {
                Text("Text vor einer Anfrage über Widget oder Antwort-Notiz.")
            }

            AIModelSection()
        }
        .navigationTitle("KI-Antworten")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AudioSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Bitrate", selection: $settings.bitrate) {
                    Text("16 kbit/s").tag(16000)
                    Text("24 kbit/s").tag(24000)
                    Text("32 kbit/s").tag(32000)
                }
            } footer: {
                Text("24 kbit/s ist empfohlen und braucht etwa 11 MiB pro Stunde.")
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
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
        .disabled(busy || school.isEmpty || username.isEmpty || password.isEmpty || !model.connectivity.isOnline)
        if !model.connectivity.isOnline {
            Text("Zum Anmelden wird eine Verbindung zum Server gebraucht.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var connectedSubtitle: String {
        if let current = model.timetable.current {
            return "Aktuell: \(current.title)"
        }
        if let next = model.timetable.next {
            return "Als Nächstes: \(next.title) · \(next.start)"
        }
        // The login lives on the server and is untouched by any of this; only
        // the ability to ask about it is missing.
        if !model.connectivity.isOnline {
            guard let savedAt = model.timetable.savedAt else {
                return "Die Anmeldung bleibt bestehen."
            }
            return "Stundenplan von \(CacheAge.phrase(savedAt))"
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
                + "Die Zugangsdaten bleiben auf deinem Server."
        }
        return "Verbindet Aufnahmen automatisch mit Fächern. Das Passwort bleibt auf deinem Server."
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

/// A row of colours for the record control, the way a list picks its colour in
/// Erinnerungen: the swatches themselves are the control.
struct RecordTintPicker: View {
    @Binding var hue: Double

    private var selected: RecordTint { RecordTint.nearest(to: hue) }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(RecordTint.allCases) { tint in
                Button {
                    hue = tint.shift
                } label: {
                    Circle()
                        .fill(tint.swatch)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if tint == selected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle().stroke(.primary.opacity(tint == selected ? 0.35 : 0), lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tint.title)
                .accessibilityAddTraits(tint == selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: selected)
    }
}
