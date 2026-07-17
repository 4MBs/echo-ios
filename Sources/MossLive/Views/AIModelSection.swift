import SwiftUI

/// Which AI backend the server uses. With ChatGPT, the model and the
/// reasoning effort are picked here; the choice is stored on the server (like
/// the WebUntis login) and applies immediately, no restart needed. The model
/// list — including which reasoning efforts each model supports — comes from
/// the server, so new models appear without an app update.
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
                        ForEach(modelChoices) { choice in
                            Text(displayName(for: choice)).tag(choice.id)
                        }
                    }
                    // only the efforts the selected model actually supports
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

    // A stored model the list doesn't know (e.g. set via config file) must
    // stay a valid tag, or the picker silently shows nothing selected.
    private var modelChoices: [BackendAPI.ModelChoice] {
        guard let settings else { return [] }
        var choices = settings.chatgptModels
        if !choices.contains(where: { $0.id == settings.chatgptModel }) {
            choices.append(.init(id: settings.chatgptModel, label: "", efforts: []))
        }
        return choices
    }

    /// "" (Standard) plus what the selected model supports; a custom model
    /// without catalog data falls back to the full list.
    private var effortChoices: [String] {
        guard let settings else { return [""] }
        let known = supportedEfforts(for: settings.chatgptModel, in: settings)
        let efforts = known.isEmpty ? settings.reasoningEfforts.filter { !$0.isEmpty } : known
        var choices = [""] + efforts
        if !choices.contains(settings.chatgptReasoningEffort) {
            choices.append(settings.chatgptReasoningEffort)
        }
        return choices
    }

    private func supportedEfforts(for modelID: String, in settings: BackendAPI.AnswerSettings) -> [String] {
        settings.chatgptModels.first { $0.id == modelID }?.efforts ?? []
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings?.chatgptModel ?? "" },
            set: { value in
                guard var updated = settings else { return }
                updated.chatgptModel = value
                // an effort the new model doesn't support goes back to Standard
                let known = supportedEfforts(for: value, in: updated)
                if !known.isEmpty, !updated.chatgptReasoningEffort.isEmpty,
                   !known.contains(updated.chatgptReasoningEffort) {
                    updated.chatgptReasoningEffort = ""
                }
                settings = updated
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

    private func displayName(for choice: BackendAPI.ModelChoice) -> String {
        if choice.id.isEmpty { return "Standard (empfohlen)" }
        return choice.label.isEmpty ? Self.modelLabel(choice.id) : choice.label
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
        case "": "Standard"
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
