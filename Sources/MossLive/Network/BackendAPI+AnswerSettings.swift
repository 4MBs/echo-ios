import Foundation

/// AI backend settings: which subscription the server uses, and the knobs the
/// app may turn on it — ChatGPT's and Claude's model, reasoning effort and
/// service tier, Gemini's model and effort — from Einstellungen.
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
        var provider: String // "gemini" | "chatgpt" | "claude"
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
        /// Claude reads like ChatGPT — a model, an effort and a speed, each
        /// its own value. All optional: a server from before Claude was a
        /// provider sends none of them, and `claudeModels == nil` is what tells
        /// the app not to offer Claude at all rather than offer one the server
        /// would refuse.
        var claudeModel: String? // "" = the CLI's own default
        var claudeEffort: String?
        var claudeServiceTier: String? // "default" = standard speed
        let claudeModels: [ModelChoice]?
        let claudeEfforts: [String]?

        var supportsClaude: Bool { claudeModels != nil }
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
        geminiModel: String,
        claudeModel: String? = nil,
        claudeEffort: String? = nil,
        claudeServiceTier: String? = nil
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
        // Claude's empty model *is* a choice (the CLI's own default), so nil —
        // a server that never sent the key — is what gets left out here.
        if let claudeModel { body["claude_model"] = claudeModel }
        if let claudeEffort { body["claude_effort"] = claudeEffort }
        if let claudeServiceTier { body["claude_service_tier"] = claudeServiceTier }
        _ = try await request("/answer/settings", method: "POST", jsonBody: body)
    }
}
