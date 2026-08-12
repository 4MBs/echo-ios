import Foundation
import Observation

/// One live copy of the server's AI configuration shared by Settings and both
/// chat composers. Changing a Codex model in one place is therefore reflected
/// everywhere else without waiting for another server fetch.
@MainActor
@Observable
final class AIConfigurationStore {
    private(set) var settings: BackendAPI.AnswerSettings?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func load(api: BackendAPI, force: Bool = false) async {
        guard force || settings == nil else { return }
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

        // A reasoning level unsupported by the new model falls back to that
        // model's default instead of making the server reject the change.
        let supported = supportedEfforts(for: modelID, in: updated)
        if !supported.isEmpty,
           !updated.chatgptReasoningEffort.isEmpty,
           !supported.contains(updated.chatgptReasoningEffort) {
            updated.chatgptReasoningEffort = ""
        }
        persist(updated, api: api)
    }

    func selectReasoningEffort(_ effort: String, api: BackendAPI) {
        guard var updated = settings, updated.chatgptReasoningEffort != effort else { return }
        updated.chatgptReasoningEffort = effort
        persist(updated, api: api)
    }

    func modelChoices(for settings: BackendAPI.AnswerSettings) -> [BackendAPI.ModelChoice] {
        var choices = settings.chatgptModels
        if !choices.contains(where: { $0.id == settings.chatgptModel }) {
            choices.append(.init(id: settings.chatgptModel, label: "", efforts: []))
        }
        return choices
    }

    func effortChoices(for settings: BackendAPI.AnswerSettings) -> [String] {
        let supported = supportedEfforts(for: settings.chatgptModel, in: settings)
        let available = supported.isEmpty
            ? settings.reasoningEfforts.filter { !$0.isEmpty }
            : supported
        var choices = [""] + available
        if !choices.contains(settings.chatgptReasoningEffort) {
            choices.append(settings.chatgptReasoningEffort)
        }
        return choices
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
        saveTask = Task { [weak self] in
            do {
                try await api.updateAnswerSettings(
                    provider: updated.provider,
                    model: updated.chatgptModel,
                    reasoningEffort: updated.chatgptReasoningEffort
                )
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
