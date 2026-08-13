import SwiftUI

/// Everything about the AI in one place: how much of the lesson a question
/// carries with it, and which model answers it.
struct AISettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Stepper(value: $settings.contextSeconds, in: 10 ... 120, step: 5) {
                    HStack {
                        Text("Kontextfenster")
                        Spacer(minLength: 12)
                        Text("\(Int(settings.contextSeconds)) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .animation(.snappy, value: settings.contextSeconds)
            } footer: {
                Text("Sekunden Transkript, die eine Frage aus dem Widget oder vom Aufnahme-Bildschirm mitschickt.")
            }

            AIModelSection()
        }
        .navigationTitle("KI")
    }
}

/// Which AI backend the server uses. With ChatGPT, the model and the
/// reasoning effort and speed are picked here; the choice is stored on the
/// server (like the WebUntis login) and applies immediately, no restart needed. The model
/// list — including which reasoning efforts each model supports — comes from
/// the server, so new models appear without an app update.
struct AIModelSection: View {
    @Environment(AppModel.self) private var model

    private var configuration: AIConfigurationStore { model.aiConfiguration }

    var body: some View {
        Section {
            if let settings {
                Picker("Anbieter", selection: providerBinding) {
                    Text("Gemini").tag("gemini")
                    Text("ChatGPT").tag("chatgpt")
                }
                .pickerStyle(.navigationLink)
                if settings.provider == "chatgpt" {
                    Picker("Modell", selection: modelBinding) {
                        ForEach(modelChoices) { choice in
                            Text(displayName(for: choice)).tag(choice.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Geschwindigkeit", selection: serviceTierBinding) {
                        ForEach(serviceTierChoices) { choice in
                            Text(speedLabel(choice)).tag(choice.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    // only the efforts the selected model actually supports
                    Picker("Denkaufwand", selection: effortBinding) {
                        ForEach(effortChoices, id: \.self) { effort in
                            Text(Self.effortLabel(effort)).tag(effort)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            } else if configuration.errorMessage != nil {
                Text("Server nicht erreichbar.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Anbieter") { ProgressView() }
            }
        } header: {
            Text("Modell")
        } footer: {
            Text(footerText)
        }
        .task { await configuration.load(api: api, force: true) }
    }

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    // A stored model the list doesn't know (e.g. set via config file) must
    // stay a valid tag, or the picker silently shows nothing selected.
    private var modelChoices: [BackendAPI.ModelChoice] {
        guard let settings else { return [] }
        return configuration.modelChoices(for: settings)
    }

    /// What the selected model supports; a custom model without catalog data
    /// falls back to the full list. The model default is resolved by the server,
    /// so Reasoning never needs a separate Standard row.
    private var effortChoices: [String] {
        guard let settings else { return [] }
        return configuration.effortChoices(for: settings)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { configuration.settings?.chatgptModel ?? "" },
            set: { value in
                configuration.selectModel(value, api: api)
            }
        )
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { configuration.settings?.provider ?? "chatgpt" },
            set: { value in
                configuration.selectProvider(value, api: api)
            }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: {
                guard let settings = configuration.settings else { return "" }
                return configuration.reasoningEffort(for: settings)
            },
            set: { value in
                configuration.selectReasoningEffort(value, api: api)
            }
        )
    }

    private var serviceTierChoices: [BackendAPI.ServiceTierChoice] {
        guard let settings else { return [] }
        return configuration.serviceTierChoices(for: settings)
    }

    private var serviceTierBinding: Binding<String> {
        Binding(
            get: {
                guard let settings = configuration.settings else { return "default" }
                return configuration.serviceTier(for: settings)
            },
            set: { value in
                configuration.selectServiceTier(value, api: api)
            }
        )
    }

    private var footerText: String {
        guard let settings else {
            return "Wird vom Server geladen."
        }
        if settings.provider == "chatgpt" {
            return "Gilt für Antworten, Zusammenfassungen und Chat — sofort."
        }
        return "Gemini wird für Antworten, Zusammenfassungen und Chat verwendet — sofort."
    }

    private func displayName(for choice: BackendAPI.ModelChoice) -> String {
        if choice.id.isEmpty { return "Standard (empfohlen)" }
        if choice.id.lowercased().hasPrefix("gpt-") { return Self.modelLabel(choice.id) }
        return choice.label.isEmpty ? Self.modelLabel(choice.id) : choice.label
    }

    private func speedLabel(_ choice: BackendAPI.ServiceTierChoice) -> String {
        switch choice.id {
        case "default": return "Standard – Standardnutzung"
        case "priority", "fast": return "Schnell – erhöhter Verbrauch"
        default:
            let label = choice.label.localizedCaseInsensitiveCompare("Fast") == .orderedSame
                ? "Schnell"
                : choice.label
            return choice.description.isEmpty ? label : "\(label) – \(choice.description)"
        }
    }

    /// Fallback prettifier for models the server has no label for:
    /// "gpt-5.6-luna" -> "GPT-5.6 Luna".
    static func modelLabel(_ slug: String) -> String {
        var parts = slug.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return slug.uppercased() }
        if parts[0].lowercased() == "gpt" { parts[0] = "GPT" }
        let family = "\(parts[0])-\(parts[1])"
        let variant = parts.dropFirst(2).map(\.capitalized).joined(separator: " ")
        return variant.isEmpty ? family : "\(family) \(variant)"
    }

    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "minimal": "Minimal – am schnellsten"
        case "low": "Niedrig – schnell"
        case "medium": "Mittel"
        case "high": "Hoch – gründlich"
        case "xhigh": "Sehr hoch"
        case "max": "Maximal – am gründlichsten"
        case "ultra": "Ultra – delegiert Teilaufgaben"
        default: effort
        }
    }

    private var settings: BackendAPI.AnswerSettings? { configuration.settings }

    private var errorMessage: String? { configuration.errorMessage }
}
