import Foundation

/// AI backend settings: which subscription the server uses, and the knobs the
/// app may turn on it — ChatGPT's model, reasoning effort and service tier,
/// Gemini's model and effort — from Einstellungen.
extension BackendAPI {
    struct ServiceTierChoice: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let label: String
        let description: String
    }

    /// One selectable model. `id` "" is the server default model; the server
    /// reads reasoning and service-tier support from the provider's own CLI
    /// catalog, so the app never hardcodes model capabilities.
    ///
    /// Gemini uses the same shape, where `id` is a model family
    /// (`gemini-3.6-flash`) and `efforts` are the identifiers it was listed at.
    struct ModelChoice: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let label: String
        let efforts: [String]
        let defaultEffort: String?
        let serviceTiers: [ServiceTierChoice]?
    }

    /// The choice lists come from the server so new models appear in the
    /// picker without an app update.
    struct AnswerSettings: Decodable, Sendable {
        var provider: String // "gemini" | "chatgpt"
        var chatgptModel: String // "" = server default
        var chatgptReasoningEffort: String
        var chatgptServiceTier: String? // "default" = standard usage
        let chatgptModels: [ModelChoice]
        let reasoningEfforts: [String]
        /// The whole Antigravity identifier, effort included
        /// (`gemini-3.6-flash-low`). Optional so a server from before the app
        /// could pick one still decodes.
        var geminiModel: String?
        let geminiModels: [ModelChoice]?
    }

    func answerSettings() async throws -> AnswerSettings {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await decoder.decode(AnswerSettings.self, from: request("/answer/settings"))
    }

    /// Switch provider/model on the running server and persist the choice.
    func updateAnswerSettings(
        provider: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String,
        geminiModel: String
    ) async throws {
        var body: [String: Any] = [
            "provider": provider,
            "chatgpt_model": model,
            "chatgpt_reasoning_effort": reasoningEffort,
            "chatgpt_service_tier": serviceTier,
        ]
        // Left out rather than sent empty: an empty model name is not one, and
        // the server would rightly refuse the whole request over it.
        if !geminiModel.isEmpty { body["gemini_model"] = geminiModel }
        _ = try await request("/answer/settings", method: "POST", jsonBody: body)
    }
}
