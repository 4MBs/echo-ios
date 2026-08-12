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

                    Divider()

                    Section("Intelligenz") {
                        ForEach(sortedEfforts(for: settings), id: \.self) { effort in
                            Button {
                                configuration.selectReasoningEffort(effort, api: api)
                            } label: {
                                if effort == settings.chatgptReasoningEffort {
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
            HStack(spacing: 5) {
                if configuration.isLoading, configuration.settings == nil {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(compactSelectionLabel)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        Label(Self.modelLabel(choice), systemImage: "checkmark")
                    } else {
                        Text(Self.modelLabel(choice))
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Modell")
                Text(Self.modelLabel(for: settings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactSelectionLabel: String {
        guard let settings = configuration.settings else { return "Modell" }
        guard settings.provider == "chatgpt" else { return "Gemini" }
        let modelName = Self.modelLabel(for: settings)
            .replacingOccurrences(of: "GPT-", with: "")
        return "\(modelName) \(Self.intelligenceLabel(settings.chatgptReasoningEffort))"
    }

    /// ChatGPT presents intelligence from strongest to lightest. Keep an
    /// explicit "Standard" at the end for the server/model default.
    private func sortedEfforts(for settings: BackendAPI.AnswerSettings) -> [String] {
        let rank = [
            "ultra": 7,
            "max": 6,
            "xhigh": 5,
            "high": 4,
            "medium": 3,
            "low": 2,
            "minimal": 1,
            "": 0,
        ]
        return configuration.effortChoices(for: settings).sorted {
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
        return choice.label.isEmpty ? AIModelSection.modelLabel(choice.id) : choice.label
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
