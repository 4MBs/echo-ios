import Foundation
import Observation

/// One live copy of the server's AI configuration shared by Settings and both
/// chat composers. Changing a model in one place is therefore reflected
/// everywhere else without waiting for another server fetch.
@MainActor
@Observable
final class AIConfigurationStore {
    typealias PersistOperation = @Sendable (BackendAPI.AnswerSettings, BackendAPI) async throws -> Void

    private(set) var settings: BackendAPI.AnswerSettings?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let persistOperation: PersistOperation

    init(
        settings: BackendAPI.AnswerSettings? = nil,
        persistOperation: @escaping PersistOperation = { updated, api in
            let tier = updated.chatgptServiceTier.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
            try await api.updateAnswerSettings(
                provider: updated.provider,
                model: updated.chatgptModel,
                reasoningEffort: updated.chatgptReasoningEffort,
                serviceTier: tier,
                geminiModel: updated.geminiModel ?? "",
                claudeModel: updated.claudeModel,
                claudeEffort: updated.claudeEffort,
                claudeServiceTier: updated.claudeServiceTier.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    ) {
        self.settings = settings
        self.persistOperation = persistOperation
    }

    func load(api: BackendAPI, force: Bool = false) async {
        guard force || settings == nil else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await api.answerSettings()
            errorMessage = nil
        } catch {
            if settings == nil { errorMessage = error.localizedDescription }
        }
    }

    func selectProvider(_ provider: String, api: BackendAPI) {
        guard var updated = settings, updated.provider != provider else { return }
        updated.provider = provider
        persist(updated, api: api)
    }

    func selectModel(_ modelID: String, api: BackendAPI) {
        guard var updated = settings, updated.chatgptModel != modelID else { return }
        updated.chatgptModel = modelID

        // ChatGPT resets reasoning to the new model's advertised default when
        // switching models (Sol/Low -> Luna/Medium in the reference).
        if let choice = modelChoice(for: modelID, in: updated),
           let defaultEffort = choice.defaultEffort,
           !defaultEffort.isEmpty {
            updated.chatgptReasoningEffort = defaultEffort
        } else {
            let supported = supportedEfforts(for: modelID, in: updated)
            if !supported.isEmpty,
               !supported.contains(updated.chatgptReasoningEffort) {
                updated.chatgptReasoningEffort = ""
            }
        }

        let serviceTiers = modelChoice(for: modelID, in: updated)?.serviceTiers ?? []
        let selectedTier = serviceTier(for: updated)
        if selectedTier != "default",
           !serviceTiers.contains(where: { $0.id == selectedTier }) {
            updated.chatgptServiceTier = "default"
        }
        persist(updated, api: api)
    }

    func selectReasoningEffort(_ effort: String, api: BackendAPI) {
        guard var updated = settings, updated.chatgptReasoningEffort != effort else { return }
        updated.chatgptReasoningEffort = effort
        persist(updated, api: api)
    }

    func selectServiceTier(_ serviceTier: String, api: BackendAPI) {
        guard var updated = settings, self.serviceTier(for: updated) != serviceTier else { return }
        updated.chatgptServiceTier = serviceTier
        persist(updated, api: api)
    }

    // MARK: - Gemini

    /// Gemini's models are its own list, and the effort is part of the model's
    /// identifier rather than a setting beside it — so both pickers read from
    /// the same string and write it back together.
    func selectGeminiModel(_ family: String, api: BackendAPI) {
        guard let current = settings else { return }
        let choice = geminiChoice(family, in: current)
        let effort = geminiEffort(for: current)
        // Keep the effort the student had if the new model was listed at it;
        // Antigravity offers the same three nearly everywhere, so switching
        // model should not quietly change how hard it thinks.
        let supported = choice?.efforts ?? []
        let kept = supported.contains(effort)
            ? effort
            : (choice?.defaultEffort ?? supported.first ?? "")
        applyGeminiModel(GeminiModelIdentifier.join(family: family, effort: kept), api: api)
    }

    func selectGeminiEffort(_ effort: String, api: BackendAPI) {
        guard let current = settings else { return }
        applyGeminiModel(
            GeminiModelIdentifier.join(family: geminiFamily(for: current), effort: effort),
            api: api
        )
    }

    private func applyGeminiModel(_ identifier: String, api: BackendAPI) {
        guard var updated = settings, !identifier.isEmpty, updated.geminiModel != identifier else { return }
        updated.geminiModel = identifier
        persist(updated, api: api)
    }

    /// The families to choose from, plus the one that is selected if the
    /// server's list has never heard of it (a model named in the config file).
    func geminiModelChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ModelChoice] {
        var choices = settings.geminiModels ?? []
        let family = geminiFamily(for: settings)
        if !family.isEmpty, !choices.contains(where: { $0.id == family }) {
            choices.append(
                .init(id: family, label: "", efforts: [], defaultEffort: nil, serviceTiers: nil)
            )
        }
        return choices
    }

    /// The efforts the selected family was listed at. Empty for a model that
    /// has none, which is a model with no effort picker rather than one with an
    /// empty picker.
    func geminiEffortChoices(for settings: BackendAPI.AnswerSettings) -> [String] {
        geminiChoice(geminiFamily(for: settings), in: settings)?.efforts ?? []
    }

    func geminiFamily(for settings: BackendAPI.AnswerSettings) -> String {
        GeminiModelIdentifier.split(settings.geminiModel ?? "").family
    }

    func geminiEffort(for settings: BackendAPI.AnswerSettings) -> String {
        GeminiModelIdentifier.split(settings.geminiModel ?? "").effort
    }

    /// What a family is called: the server's name for it, or the identifier
    /// when the list does not carry one.
    func geminiLabel(for family: String, in settings: BackendAPI.AnswerSettings) -> String {
        let label = geminiChoice(family, in: settings)?.label ?? ""
        return label.isEmpty ? family : label
    }

    private func geminiChoice(
        _ family: String,
        in settings: BackendAPI.AnswerSettings
    ) -> BackendAPI.ModelChoice? {
        (settings.geminiModels ?? []).first { $0.id == family }
    }

    // MARK: - Claude

    // Claude's knobs are shaped like ChatGPT's — a model, an effort and a
    // speed, each stored on its own — so everything below mirrors those.

    func selectClaudeModel(_ modelID: String, api: BackendAPI) {
        guard var updated = settings, (updated.claudeModel ?? "") != modelID else { return }
        updated.claudeModel = modelID

        // Switching model lands on that model's own default effort, the way
        // ChatGPT's picker does: Haiku takes no effort at all, and carrying a
        // stale "max" onto it would only be silently dropped by the server.
        let choice = claudeChoice(modelID, in: updated)
        let supported = choice?.efforts ?? []
        if supported.isEmpty {
            updated.claudeEffort = ""
        } else if !supported.contains(claudeEffort(for: updated)) {
            var fallback = supported.first ?? ""
            if let advertised = choice?.defaultEffort, !advertised.isEmpty { fallback = advertised }
            updated.claudeEffort = fallback
        }

        let tiers = choice?.serviceTiers ?? []
        if claudeServiceTier(for: updated) != "default",
           !tiers.contains(where: { $0.id == claudeServiceTier(for: updated) }) {
            updated.claudeServiceTier = "default"
        }
        persist(updated, api: api)
    }

    func selectClaudeEffort(_ effort: String, api: BackendAPI) {
        guard var updated = settings, claudeEffort(for: updated) != effort else { return }
        updated.claudeEffort = effort
        persist(updated, api: api)
    }

    func selectClaudeServiceTier(_ serviceTier: String, api: BackendAPI) {
        guard var updated = settings, claudeServiceTier(for: updated) != serviceTier else { return }
        updated.claudeServiceTier = serviceTier
        persist(updated, api: api)
    }

    /// The models to choose from, plus the one that is selected if the server's
    /// list has never heard of it (a model named in the config file).
    func claudeModelChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ModelChoice] {
        var choices = settings.claudeModels ?? []
        let selected = claudeModel(for: settings)
        if !choices.contains(where: { $0.id == selected }) {
            choices.append(
                .init(id: selected, label: "", efforts: [], defaultEffort: nil, serviceTiers: nil)
            )
        }
        return choices
    }

    /// The efforts the selected model was listed at. Empty for a model that has
    /// none, which is a model with no effort picker rather than an empty one.
    func claudeEffortChoices(for settings: BackendAPI.AnswerSettings) -> [String] {
        let supported = claudeChoice(claudeModel(for: settings), in: settings)?.efforts ?? []
        guard !supported.isEmpty else { return [] }
        var choices = supported
        let selected = claudeEffort(for: settings)
        if !selected.isEmpty, !choices.contains(selected) { choices.append(selected) }
        return choices
    }

    func claudeServiceTierChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ServiceTierChoice] {
        let advertised = claudeChoice(claudeModel(for: settings), in: settings)?.serviceTiers ?? []
        guard !advertised.isEmpty else { return [] }
        let standard = BackendAPI.ServiceTierChoice(
            id: "default",
            label: "Standard",
            description: "Standardnutzung"
        )
        return [standard] + advertised.filter { $0.id != standard.id }
    }

    func claudeModel(for settings: BackendAPI.AnswerSettings) -> String {
        settings.claudeModel ?? ""
    }

    func claudeEffort(for settings: BackendAPI.AnswerSettings) -> String {
        if let effort = settings.claudeEffort, !effort.isEmpty { return effort }
        return claudeChoice(claudeModel(for: settings), in: settings)?.defaultEffort ?? ""
    }

    func claudeServiceTier(for settings: BackendAPI.AnswerSettings) -> String {
        let tier = settings.claudeServiceTier ?? "default"
        return tier.isEmpty ? "default" : tier
    }

    /// What a model is called: the server's name for it, the identifier when
    /// the list carries none, and "Standard" for the CLI's own default.
    func claudeLabel(for modelID: String, in settings: BackendAPI.AnswerSettings) -> String {
        if modelID.isEmpty { return "Standard" }
        let label = claudeChoice(modelID, in: settings)?.label ?? ""
        return label.isEmpty ? modelID : label
    }

    private func claudeChoice(
        _ modelID: String,
        in settings: BackendAPI.AnswerSettings
    ) -> BackendAPI.ModelChoice? {
        (settings.claudeModels ?? []).first { $0.id == modelID }
    }

    // MARK: - ChatGPT

    func modelChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ModelChoice] {
        var choices = settings.chatgptModels
        if !choices.contains(where: { $0.id == settings.chatgptModel }) {
            choices.append(
                .init(
                    id: settings.chatgptModel,
                    label: "",
                    efforts: [],
                    defaultEffort: nil,
                    serviceTiers: nil
                )
            )
        }
        return choices
    }

    func effortChoices(for settings: BackendAPI.AnswerSettings) -> [String] {
        let supported = supportedEfforts(for: settings.chatgptModel, in: settings)
        let available = supported.isEmpty
            ? settings.reasoningEfforts.filter { !$0.isEmpty }
            : supported
        var choices = available.filter { !$0.isEmpty }
        let selected = reasoningEffort(for: settings)
        if !selected.isEmpty, !choices.contains(selected) {
            choices.append(selected)
        }
        return choices
    }

    func serviceTierChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ServiceTierChoice] {
        let standard = BackendAPI.ServiceTierChoice(
            id: "default",
            label: "Standard",
            description: "Standardnutzung"
        )
        let advertised = modelChoice(for: settings.chatgptModel, in: settings)?.serviceTiers ?? []
        var choices = [standard] + advertised.filter { $0.id != standard.id }
        let selected = serviceTier(for: settings)
        if !choices.contains(where: { $0.id == selected }) {
            choices.append(.init(id: selected, label: selected, description: ""))
        }
        return choices
    }

    func reasoningEffort(for settings: BackendAPI.AnswerSettings) -> String {
        if !settings.chatgptReasoningEffort.isEmpty {
            return settings.chatgptReasoningEffort
        }
        return modelChoice(for: settings.chatgptModel, in: settings)?.defaultEffort ?? ""
    }

    func serviceTier(for settings: BackendAPI.AnswerSettings) -> String {
        let tier = settings.chatgptServiceTier ?? "default"
        return tier.isEmpty ? "default" : tier
    }

    private func modelChoice(
        for modelID: String,
        in settings: BackendAPI.AnswerSettings
    ) -> BackendAPI.ModelChoice? {
        settings.chatgptModels.first { $0.id == modelID }
    }

    private func supportedEfforts(
        for modelID: String,
        in settings: BackendAPI.AnswerSettings
    ) -> [String] {
        settings.chatgptModels.first { $0.id == modelID }?.efforts ?? []
    }

    private func persist(_ updated: BackendAPI.AnswerSettings, api: BackendAPI) {
        settings = updated
        errorMessage = nil
        saveTask?.cancel()
        let persistOperation = persistOperation
        saveTask = Task { [weak self] in
            do {
                try await persistOperation(updated, api)
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                await self?.load(api: api, force: true)
                guard !Task.isCancelled else { return }
                self?.errorMessage = message
            }
        }
    }
}
