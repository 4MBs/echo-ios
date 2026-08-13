import SwiftUI

/// ChatGPT-style model control for a composer: the current Codex model and
/// intelligence level stay compact until tapped, then expand into native,
/// nested menus with a checkmark on each active choice.
struct AIModelMenu: View {
    @Environment(AppModel.self) private var model

    private var configuration: AIConfigurationStore { model.aiConfiguration }

    private var api: BackendAPI {
        BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
    }

    var body: some View {
        Menu {
            if let settings = configuration.settings {
                if settings.provider == "chatgpt" {
                    modelSubmenu(settings)
                    speedSubmenu(settings)

                    Divider()

                    Section("Intelligenz") {
                        ForEach(sortedEfforts(for: settings), id: \.self) { effort in
                            Button {
                                configuration.selectReasoningEffort(effort, api: api)
                            } label: {
                                if effort == configuration.reasoningEffort(for: settings) {
                                    Label(Self.intelligenceLabel(effort), systemImage: "checkmark")
                                } else {
                                    Text(Self.intelligenceLabel(effort))
                                }
                            }
                        }
                    }
                } else {
                    Text("Gemini ist in den Einstellungen aktiviert.")
                }
            } else if configuration.isLoading {
                Text("Modelle werden geladen …")
            } else {
                Text(configuration.errorMessage ?? "Modelle nicht verfügbar")
            }
        } label: {
            Group {
                if configuration.isLoading, configuration.settings == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(minHeight: 30)
                } else {
                    ZStack(alignment: .leading) {
                        // Reserve the exact native width of every possible value.
                        // Menu dismissal can otherwise update the text one pass
                        // before its label receives the new intrinsic width.
                        ForEach(compactSelectionCandidates, id: \.self) { candidate in
                            compactLabel(candidate, showsSpeed: true)
                                .hidden()
                                .accessibilityHidden(true)
                        }

                        compactLabel(compactSelectionLabel, showsSpeed: speedIsSelected)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .transaction { $0.animation = nil }
                    .frame(minHeight: 30)
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(configuration.settings == nil)
        .accessibilityLabel("KI-Modell: \(compactSelectionLabel)")
        .task { await configuration.load(api: api) }
    }

    private func modelSubmenu(_ settings: BackendAPI.AnswerSettings) -> some View {
        Menu {
            ForEach(configuration.modelChoices(for: settings)) { choice in
                Button {
                    configuration.selectModel(choice.id, api: api)
                } label: {
                    if choice.id == settings.chatgptModel {
                        Label(Self.menuModelLabel(choice), systemImage: "checkmark")
                    } else {
                        Text(Self.menuModelLabel(choice))
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Modell")
                Text(Self.menuModelLabel(for: settings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuOrder(.fixed)
    }

    private func speedSubmenu(_ settings: BackendAPI.AnswerSettings) -> some View {
        Menu {
            ForEach(configuration.serviceTierChoices(for: settings)) { choice in
                Button {
                    configuration.selectServiceTier(choice.id, api: api)
                } label: {
                    if choice.id == configuration.serviceTier(for: settings) {
                        Label {
                            speedChoiceLabel(choice)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        speedChoiceLabel(choice)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Geschwindigkeit")
                Text(selectedSpeedLabel(for: settings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuOrder(.fixed)
    }

    private func speedChoiceLabel(_ choice: BackendAPI.ServiceTierChoice) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.speedLabel(choice.id, fallback: choice.label))
            Text(Self.speedDescription(choice.id, fallback: choice.description))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedSpeedLabel(for settings: BackendAPI.AnswerSettings) -> String {
        let selected = configuration.serviceTier(for: settings)
        let advertised = configuration.serviceTierChoices(for: settings).first { $0.id == selected }
        return Self.speedLabel(selected, fallback: advertised?.label ?? "")
    }

    private var compactSelectionLabel: String {
        guard let settings = configuration.settings else { return "Modell" }
        guard settings.provider == "chatgpt" else { return "Gemini" }
        let modelName = Self.modelLabel(for: settings)
            .replacingOccurrences(of: "GPT-", with: "")
        let effort = configuration.reasoningEffort(for: settings)
        return "\(modelName) \(Self.intelligenceLabel(effort))"
    }

    private var speedIsSelected: Bool {
        guard let settings = configuration.settings else { return false }
        return configuration.serviceTier(for: settings) != "default"
    }

    private var compactSelectionCandidates: [String] {
        guard let settings = configuration.settings, settings.provider == "chatgpt" else {
            return [compactSelectionLabel]
        }
        let efforts = configuration.effortChoices(for: settings)
        let candidates = configuration.modelChoices(for: settings).flatMap { choice in
            let modelName = Self.modelLabel(choice).replacingOccurrences(of: "GPT-", with: "")
            return efforts.map { "\(modelName) \(Self.intelligenceLabel($0))" }
        } + [compactSelectionLabel]
        return Array(Set(candidates)).sorted()
    }

    private func compactLabel(_ text: String, showsSpeed: Bool) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "bolt.fill")
                .opacity(showsSpeed ? 1 : 0)
        }
        .font(.caption.weight(.medium))
    }

    /// ChatGPT presents intelligence from strongest to lightest. Its picker
    /// exposes the five visible levels from the recording, without a Standard
    /// row or Codex's advanced Minimal/Ultra aliases.
    private func sortedEfforts(for settings: BackendAPI.AnswerSettings) -> [String] {
        let rank = [
            "max": 5,
            "xhigh": 4,
            "high": 3,
            "medium": 2,
            "low": 1,
        ]
        return configuration.effortChoices(for: settings).filter { rank[$0] != nil }.sorted {
            rank[$0, default: 0] > rank[$1, default: 0]
        }
    }

    private static func modelLabel(for settings: BackendAPI.AnswerSettings) -> String {
        guard let choice = settings.chatgptModels.first(where: { $0.id == settings.chatgptModel }) else {
            if settings.chatgptModel.isEmpty { return "Standard" }
            return AIModelSection.modelLabel(settings.chatgptModel)
        }
        return modelLabel(choice)
    }

    private static func modelLabel(_ choice: BackendAPI.ModelChoice) -> String {
        if choice.id.isEmpty { return "Standard" }
        if choice.id.lowercased().hasPrefix("gpt-") {
            return AIModelSection.modelLabel(choice.id)
        }
        return choice.label.isEmpty ? AIModelSection.modelLabel(choice.id) : choice.label
    }

    private static func menuModelLabel(for settings: BackendAPI.AnswerSettings) -> String {
        modelLabel(for: settings).replacingOccurrences(of: "GPT-", with: "")
    }

    private static func menuModelLabel(_ choice: BackendAPI.ModelChoice) -> String {
        modelLabel(choice).replacingOccurrences(of: "GPT-", with: "")
    }

    private static func speedLabel(_ serviceTier: String, fallback: String = "") -> String {
        switch serviceTier {
        case "default": return "Standard"
        case "priority", "fast": return "Schnell"
        default:
            if fallback.localizedCaseInsensitiveCompare("Fast") == .orderedSame { return "Schnell" }
            return fallback.isEmpty ? serviceTier : fallback
        }
    }

    private static func speedDescription(_ serviceTier: String, fallback: String) -> String {
        switch serviceTier {
        case "default": "Standardnutzung"
        case "priority", "fast": "Erhöhter Verbrauch"
        default: fallback
        }
    }

    /// The compact language from the ChatGPT menu in the reference recording.
    private static func intelligenceLabel(_ effort: String) -> String {
        switch effort {
        case "": "Standard"
        case "minimal": "Minimal"
        case "low": "Leicht"
        case "medium": "Mittel"
        case "high": "Hoch"
        case "xhigh": "Sehr hoch"
        case "max": "Max"
        case "ultra": "Ultra"
        default: effort
        }
    }
}
