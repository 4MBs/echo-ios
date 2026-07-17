import SwiftUI

/// Which AI backend the server uses. With ChatGPT, the model and the
/// reasoning effort are picked here; the choice is stored on the server (like
/// the WebUntis login) and applies immediately, no restart needed. The model
/// list comes from the server, so new models appear without an app update.
struct AIModelSection: View {
    @Environment(AppModel.self) private var model

    @State private var settings: BackendAPI.AnswerSettings?
    @State private var loadFailed = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let settings {
                LabeledContent("Anbieter", value: settings.provider == "chatgpt" ? "ChatGPT" : "Gemini")
                if settings.provider == "chatgpt" {
                    Picker("Modell", selection: modelBinding) {
                        ForEach(modelChoices, id: \.self) { slug in
                            Text(Self.modelLabel(slug)).tag(slug)
                        }
                    }
                    Picker("Denkaufwand", selection: effortBinding) {
                        ForEach(effortChoices, id: \.self) { effort in
                            Text(Self.effortLabel(effort)).tag(effort)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            } else if loadFailed {
                Text("Nicht verfügbar – Server nicht erreichbar oder noch ohne Update.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Anbieter") { ProgressView() }
            }
        } header: {
            Text("KI-Modell")
        } footer: {
            Text(footerText)
        }
        .task { await load() }
    }

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    // A stored value the list doesn't know (e.g. set via config file) must
    // stay a valid tag, or the picker silently shows nothing selected.
    private var modelChoices: [String] {
        var choices = settings?.chatgptModels ?? [""]
        if let current = settings?.chatgptModel, !choices.contains(current) {
            choices.append(current)
        }
        return choices
    }

    private var effortChoices: [String] {
        var choices = settings?.reasoningEfforts ?? [""]
        if let current = settings?.chatgptReasoningEffort, !choices.contains(current) {
            choices.append(current)
        }
        return choices
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings?.chatgptModel ?? "" },
            set: { value in
                settings?.chatgptModel = value
                save()
            }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { settings?.chatgptReasoningEffort ?? "" },
            set: { value in
                settings?.chatgptReasoningEffort = value
                save()
            }
        )
    }

    private var footerText: String {
        guard let settings else {
            return "Modell-Einstellungen werden vom Server geladen."
        }
        if settings.provider == "chatgpt" {
            return "Modell und Denkaufwand gelten für Antworten, Zusammenfassungen, Chat und "
                + "Quizfragen. Die Auswahl wird auf deinem Server gespeichert und gilt sofort. "
                + "\"Standard\" nutzt immer das aktuell empfohlene ChatGPT-Modell."
        }
        return "Dein Server nutzt Gemini. Zum Wechseln auf ChatGPT setze auf dem Server "
            + "answer.provider = \"chatgpt\" in ~/.config/mosslive/config.toml."
    }

    /// "gpt-5.6-luna" -> "GPT-5.6 Luna"; "" -> Standard.
    static func modelLabel(_ slug: String) -> String {
        if slug.isEmpty { return "Standard (empfohlen)" }
        var parts = slug.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return slug.uppercased() }
        if parts[0].lowercased() == "gpt" { parts[0] = "GPT" }
        let family = "\(parts[0])-\(parts[1])"
        let variant = parts.dropFirst(2).map(\.capitalized).joined(separator: " ")
        return variant.isEmpty ? family : "\(family) \(variant)"
    }

    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "": "Standard"
        case "minimal": "Minimal – am schnellsten"
        case "low": "Niedrig – schnell"
        case "medium": "Mittel"
        case "high": "Hoch – gründlich"
        case "xhigh": "Sehr hoch – am gründlichsten"
        default: effort
        }
    }

    private func save() {
        guard let settings else { return }
        errorMessage = nil
        Task {
            do {
                try await api.updateAnswerSettings(
                    model: settings.chatgptModel,
                    reasoningEffort: settings.chatgptReasoningEffort
                )
            } catch {
                errorMessage = error.localizedDescription
                await load()
            }
        }
    }

    private func load() async {
        do {
            settings = try await api.answerSettings()
            loadFailed = false
            errorMessage = nil
        } catch {
            loadFailed = settings == nil
        }
    }
}
