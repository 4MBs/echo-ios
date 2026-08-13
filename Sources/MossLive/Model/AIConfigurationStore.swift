import Foundation
import Observation

/// One live copy of the server's AI configuration shared by Settings and both
/// chat composers. Changing a Codex model in one place is therefore reflected
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
                serviceTier: tier
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
