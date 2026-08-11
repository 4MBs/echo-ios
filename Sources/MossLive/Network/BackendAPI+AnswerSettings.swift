import Foundation

/// AI backend settings: which subscription the server uses, and the ChatGPT
/// knobs (model, reasoning effort) the app may tune from Einstellungen.
extension BackendAPI {
    /// One selectable ChatGPT model. `id` "" is the server default model; the
    /// server reads `efforts` from the codex CLI's own model catalog, so the
    /// app never hardcodes which model supports which reasoning effort.
    struct ModelChoice: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let label: String
        let efforts: [String]
    }

    /// The choice lists come from the server so new models appear in the
    /// picker without an app update.
    struct AnswerSettings: Decodable, Sendable {
        var provider: String // "gemini" | "chatgpt"
        var chatgptModel: String // "" = server default
        var chatgptReasoningEffort: String // "" = model default
        let chatgptModels: [ModelChoice]
        let reasoningEfforts: [String]
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
        reasoningEffort: String
    ) async throws {
        _ = try await request(
            "/answer/settings",
            method: "POST",
            jsonBody: [
                "provider": provider,
                "chatgpt_model": model,
                "chatgpt_reasoning_effort": reasoningEffort,
            ]
        )
    }
}
