import SwiftUI

// The pages behind the settings index. Each one holds a single subject, which
// is what lets the explanations shrink to a line: a control on a page called
// "Aufnahme" no longer has to say that it is about recording.

// MARK: - Server

/// Where the app finds the backend. The three fields are the whole setup, so
/// the page leads with whether they currently work.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Verbindung") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.text)
                    }
                }
            }

            // Label left, field right — the shape Apple gives a form whose
            // rows are settings rather than a sign-in.
            Section {
                LabeledContent("Adresse") {
                    TextField("100.101.102.103", text: $settings.serverHost)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Port") {
                    TextField("8787", value: $settings.serverPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                LabeledContent("Token") {
                    SecureField("erforderlich", text: $settings.authToken)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("Adresse: `tailscale ip -4`. Token: `MOSSLIVE_AUTH_TOKEN` aus `~/.config/mosslive/env`.")
            }
        }
        .navigationTitle("Server")
    }

    private var status: (text: String, color: Color) {
        guard model.settings.isConfigured else { return ("Nicht eingerichtet", .secondary) }
        return model.connectivity.isOnline ? ("Verbunden", .green) : ("Nicht erreichbar", .orange)
    }
}

// MARK: - Aufnahme

struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Farbe des Aufnahmeknopfs") {
                RecordTintPicker(hue: $settings.recordButtonHue)
            }

            Section {
                Picker("Bitrate", selection: $settings.bitrate) {
                    Text("16 kbit/s").tag(16000)
                    Text("24 kbit/s").tag(24000)
                    Text("32 kbit/s").tag(32000)
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Audio")
            } footer: {
                Text("24 kbit/s ist empfohlen und entspricht etwa 11 MiB pro Stunde.")
            }
        }
        .navigationTitle("Aufnahme")
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
        .sensoryFeedback(.selection, trigger: selected)
        .animation(.snappy, value: selected)
    }
}

// MARK: - Lernen

struct LearnSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Name") {
                    TextField(
                        "Name",
                        text: $settings.displayName,
                        prompt: Text(AppSettings.defaultDisplayName)
                    )
                    .multilineTextAlignment(.trailing)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                }
            } header: {
                Text("Begrüßung")
            } footer: {
                Text("Steht oben im Lernen-Tab: „Hallo, \(model.settings.greetingName)“.")
            }

            Section {
                Toggle("Tägliche Erinnerung", isOn: enabledBinding)
                if model.settings.learnReminderEnabled {
                    DatePicker("Uhrzeit", selection: timeBinding, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Einmal am Tag, wenn Karten fällig sind.")
            }
        }
        .navigationTitle("Lernen")
        .animation(.snappy, value: model.settings.learnReminderEnabled)
    }

    private var enabledBinding: Binding<Bool> {
        let settings = model.settings
        return Binding(
            get: { settings.learnReminderEnabled },
            set: { value in
                settings.learnReminderEnabled = value
                Task { await LearnReminder.sync(enabled: value, minuteOfDay: settings.learnReminderMinutes) }
            }
        )
    }

    private var timeBinding: Binding<Date> {
        let settings = model.settings
        return Binding(
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

// MARK: - Bibliothek

struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Seitenzahlen anpassen", isOn: $settings.showPageNumberEditor)
            } footer: {
                Text("Zeigt im Buch den Knopf für die gedruckte Seitenzahl. Eingestellte Zahlen bleiben erhalten.")
            }
        }
        .navigationTitle("Bibliothek")
    }
}

// MARK: - App-Wechsel

/// The apps the three-finger tap offers, plus whatever URL scheme has been
/// typed in instead. A stored scheme that matches none of them is `.custom`,
/// so the picker can never end up showing nothing.
enum QuickSwitchApp: String, CaseIterable, Identifiable {
    case goodNotes, notizen, safari, buecher, eigene

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goodNotes: "GoodNotes"
        case .notizen: "Notizen"
        case .safari: "Safari"
        case .buecher: "Bücher"
        case .eigene: "Eigene URL"
        }
    }

    /// The legacy `goodnotes5://` launcher scheme, not `goodnotes://`: the bare
    /// one lands in GoodNotes' file import and shows an error.
    var scheme: String? {
        switch self {
        case .goodNotes: "goodnotes5://"
        case .notizen: "mobilenotes://"
        case .safari: "https://www.google.com"
        case .buecher: "ibooks://"
        case .eigene: nil
        }
    }

    init(urlString: String) {
        self = Self.allCases.first { $0.scheme == urlString } ?? .eigene
    }
}

struct QuickSwitchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("App", selection: appBinding) {
                    ForEach(QuickSwitchApp.allCases) { app in
                        Text(app.title).tag(app)
                    }
                }
                .pickerStyle(.navigationLink)
                // Only when there is nothing to pick from: the field used to
                // sit under the picker permanently and repeat its answer.
                if appBinding.wrappedValue == .eigene {
                    TextField("URL-Schema", text: $settings.quickSwitchURL, prompt: Text("goodnotes5://"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text("Mit drei Fingern tippen wechselt sofort in diese App. Die Aufnahme läuft weiter.")
            }
        }
        .navigationTitle("App-Wechsel")
        .animation(.snappy, value: appBinding.wrappedValue)
    }

    private var appBinding: Binding<QuickSwitchApp> {
        let settings = model.settings
        return Binding(
            get: { QuickSwitchApp(urlString: settings.quickSwitchURL) },
            set: { app in
                if let scheme = app.scheme {
                    settings.quickSwitchURL = scheme
                } else if QuickSwitchApp(urlString: settings.quickSwitchURL) != .eigene {
                    // switching to "Eigene URL" from a preset clears the field
                    // rather than leaving the preset's scheme in it to edit
                    settings.quickSwitchURL = ""
                }
            }
        )
    }
}

// MARK: - Über

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Transkription", value: "Qwen3-ASR 1.7B")
            }

            Section {
                LabeledContent("Widget-Verbindung", value: SharedConfig.resolvedGroupID ?? "nicht verfügbar")
                    .font(.footnote)
                    .textSelection(.enabled)
            } footer: {
                Text("Audio wird nur auf deinem eigenen Server verarbeitet. An eine KI geht allein der "
                    + "Transkript-Ausschnitt, den eine Frage mitschickt.")
            }
        }
        .navigationTitle("Über Echo")
    }
}
