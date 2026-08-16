import SwiftUI

/// ChatGPT-style model control for a composer: the current model and
/// intelligence level stay compact until tapped, then expand into native,
/// nested menus with a checkmark on each active choice.
///
/// Every provider is picked from here. Gemini used to say only that it was
/// enabled in Settings, which left the one provider whose model can matter most
/// during a lesson — Flash answers in about two seconds, Pro does not —
/// unswitchable from where the question is asked.
///
/// The three providers differ in what they offer, not in how it is shown, so
/// the submenus below are written once and handed each provider's own choices:
/// a third near-identical copy of "a menu of models with a checkmark" is how a
/// file like this stops being readable.
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
                switch settings.provider {
                case "chatgpt": chatgptMenu(settings)
                case "claude": claudeMenu(settings)
                default: geminiMenu(settings)
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
                        // Measure the current value in the same pass in which it
                        // becomes visible. A fresh identity below prevents Menu
                        // from briefly reusing the previous label's narrower
                        // intrinsic width, without permanently reserving the
                        // widest possible model/reasoning combination.
                        compactLabel(compactSelectionLabel, showsSpeed: speedIsSelected)
                            .hidden()
                            .accessibilityHidden(true)

                        compactLabel(compactSelectionLabel, showsSpeed: speedIsSelected)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .id("\(compactSelectionLabel)-\(speedIsSelected)")
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

    // MARK: - One menu per provider

    @ViewBuilder
    private func chatgptMenu(_ settings: BackendAPI.AnswerSettings) -> some View {
        modelSubmenu(
            choices: configuration.modelChoices(for: settings),
            selected: settings.chatgptModel,
            selectedLabel: Self.menuModelLabel(for: settings),
            label: { Self.menuModelLabel($0) },
            select: { configuration.selectModel($0, api: api) }
        )
        // Codex advertises a speed on every model, so this row is always here
        // even when "Standard" is the only thing in it.
        speedSubmenu(
            choices: configuration.serviceTierChoices(for: settings),
            selected: configuration.serviceTier(for: settings),
            select: { configuration.selectServiceTier($0, api: api) }
        )
        effortSection(
            Self.sortedByStrength(configuration.effortChoices(for: settings)),
            selected: configuration.reasoningEffort(for: settings),
            label: { Self.intelligenceLabel($0) },
            select: { configuration.selectReasoningEffort($0, api: api) }
        )
    }

    @ViewBuilder
    private func claudeMenu(_ settings: BackendAPI.AnswerSettings) -> some View {
        modelSubmenu(
            choices: configuration.claudeModelChoices(for: settings),
            selected: configuration.claudeModel(for: settings),
            selectedLabel: configuration.claudeLabel(
                for: configuration.claudeModel(for: settings),
                in: settings
            ),
            label: { Self.claudeLabel($0) },
            select: { configuration.selectClaudeModel($0, api: api) }
        )
        // Fast mode exists on some Claude models only, and Haiku takes no
        // effort at all: a row with one unchangeable choice is chrome.
        let tiers = configuration.claudeServiceTierChoices(for: settings)
        if tiers.count > 1 {
            speedSubmenu(
                choices: tiers,
                selected: configuration.claudeServiceTier(for: settings),
                select: { configuration.selectClaudeServiceTier($0, api: api) }
            )
        }
        effortSection(
            Self.sortedByStrength(configuration.claudeEffortChoices(for: settings)),
            selected: configuration.claudeEffort(for: settings),
            label: { Self.intelligenceLabel($0) },
            select: { configuration.selectClaudeEffort($0, api: api) }
        )
    }

    /// Antigravity has no speed, and carries the effort inside the model's own
    /// name — the store puts the two halves back together.
    @ViewBuilder
    private func geminiMenu(_ settings: BackendAPI.AnswerSettings) -> some View {
        let family = configuration.geminiFamily(for: settings)
        modelSubmenu(
            choices: configuration.geminiModelChoices(for: settings),
            selected: family,
            selectedLabel: configuration.geminiLabel(for: family, in: settings),
            label: { Self.geminiLabel($0) },
            select: { configuration.selectGeminiModel($0, api: api) }
        )
        effortSection(
            Array(configuration.geminiEffortChoices(for: settings).reversed()),
            selected: configuration.geminiEffort(for: settings),
            label: { GeminiModelIdentifier.effortLabel($0) },
            select: { configuration.selectGeminiEffort($0, api: api) }
        )
    }

    // MARK: - The pieces every provider is shown through

    private func modelSubmenu(
        choices: [BackendAPI.ModelChoice],
        selected: String,
        selectedLabel: String,
        label: @escaping (BackendAPI.ModelChoice) -> String,
        select: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    select(choice.id)
                } label: {
                    if choice.id == selected {
                        Label(label(choice), systemImage: "checkmark")
                    } else {
                        Text(label(choice))
                    }
                }
            }
        } label: {
            submenuLabel("Modell", selectedLabel)
        }
        .menuOrder(.fixed)
    }

    private func speedSubmenu(
        choices: [BackendAPI.ServiceTierChoice],
        selected: String,
        select: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    select(choice.id)
                } label: {
                    if choice.id == selected {
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
            let advertised = choices.first { $0.id == selected }?.label ?? ""
            submenuLabel("Geschwindigkeit", Self.speedLabel(selected, fallback: advertised))
        }
        .menuOrder(.fixed)
    }

    /// Strongest first. A provider whose selected model offers a single level
    /// gets no section at all — one row that cannot be changed is chrome.
    @ViewBuilder
    private func effortSection(
        _ efforts: [String],
        selected: String,
        label: @escaping (String) -> String,
        select: @escaping (String) -> Void
    ) -> some View {
        if efforts.count > 1 {
            Divider()

            Section("Intelligenz") {
                ForEach(efforts, id: \.self) { effort in
                    Button {
                        select(effort)
                    } label: {
                        if effort == selected {
                            Label(label(effort), systemImage: "checkmark")
                        } else {
                            Text(label(effort))
                        }
                    }
                }
            }
        }
    }

    private func submenuLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func speedChoiceLabel(_ choice: BackendAPI.ServiceTierChoice) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.speedLabel(choice.id, fallback: choice.label))
            Text(Self.speedDescription(choice.id, fallback: choice.description))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The chip

    /// The generation and the effort, with the provider's own name dropped —
    /// "3.6 Flash Leicht", "5.6 Luna Hoch", "Opus 5 Leicht". Which provider is
    /// answering is a settings decision; the chip is there to say which model.
    private var compactSelectionLabel: String {
        guard let settings = configuration.settings else { return "Modell" }
        switch settings.provider {
        case "chatgpt":
            let name = Self.modelLabel(for: settings).replacingOccurrences(of: "GPT-", with: "")
            return "\(name) \(Self.intelligenceLabel(configuration.reasoningEffort(for: settings)))"
        case "claude":
            let name = configuration
                .claudeLabel(for: configuration.claudeModel(for: settings), in: settings)
                .replacingOccurrences(of: "Claude ", with: "")
            let effort = configuration.claudeEffort(for: settings)
            return effort.isEmpty ? name : "\(name) \(Self.intelligenceLabel(effort))"
        default:
            let family = configuration.geminiFamily(for: settings)
            let name = configuration.geminiLabel(for: family, in: settings)
                .replacingOccurrences(of: "Gemini ", with: "")
            let effort = configuration.geminiEffort(for: settings)
            return effort.isEmpty ? name : "\(name) \(GeminiModelIdentifier.effortLabel(effort))"
        }
    }

    private var speedIsSelected: Bool {
        guard let settings = configuration.settings else { return false }
        switch settings.provider {
        case "chatgpt": return configuration.serviceTier(for: settings) != "default"
        case "claude": return configuration.claudeServiceTier(for: settings) != "default"
        default: return false
        }
    }

    private func compactLabel(_ text: String, showsSpeed: Bool) -> some View {
        let pieces = Self.compactLabelPieces(text)
        return HStack(spacing: 3) {
            // Footnote is the same 13 points at the default setting, but it
            // follows the student's text size instead of pinning the chip.
            Text(pieces.version).font(.footnote.weight(.semibold))
                + Text(pieces.detail).font(.footnote)
            if showsSpeed {
                Image(systemName: "bolt.fill")
            }
        }
        .font(.caption2.weight(.medium))
    }

    /// Keep the model generation slightly stronger without turning Luna, Sol,
    /// the reasoning level, or their spaces into a second badge-like label.
    private static func compactLabelPieces(_ label: String) -> (version: String, detail: String) {
        let separator = label.firstIndex(of: " ") ?? label.endIndex
        let version = String(label[..<separator])
        guard version.allSatisfy({ $0.isNumber || $0 == "." }) else { return ("", label) }
        return (
            version,
            separator == label.endIndex ? "" : String(label[separator...])
        )
    }

    // MARK: - Naming

    /// ChatGPT presents intelligence from strongest to lightest, and so does
    /// Claude — the same five levels, so both lists read the same way. Only the
    /// levels named below are offered: no Standard row, and none of Codex's
    /// advanced Minimal/Ultra aliases.
    private static func sortedByStrength(_ efforts: [String]) -> [String] {
        let rank = [
            "max": 5,
            "xhigh": 4,
            "high": 3,
            "medium": 2,
            "low": 1,
        ]
        return efforts.filter { rank[$0] != nil }.sorted {
            rank[$0, default: 0] > rank[$1, default: 0]
        }
    }

    private static func geminiLabel(_ choice: BackendAPI.ModelChoice) -> String {
        choice.label.isEmpty ? choice.id : choice.label
    }

    private static func claudeLabel(_ choice: BackendAPI.ModelChoice) -> String {
        if choice.id.isEmpty { return "Standard" }
        return choice.label.isEmpty ? choice.id : choice.label
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
