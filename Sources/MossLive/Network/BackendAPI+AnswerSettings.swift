import Foundation

/// AI backend settings: which subscription the server uses, and the ChatGPT
/// knobs (model, reasoning effort) the app may tune from Einstellungen.
extension BackendAPI {
    /// The choice lists come from the server so new models appear in the
    /// picker without an app update.
    struct AnswerSettings: Decodable, Sendable {
        let provider: String // "gemini" | "chatgpt"
        var chatgptModel: String // "" = server default
        var chatgptReasoningEffort: String // "" = server default
        let chatgptModels: [String]
        let reasoningEfforts: [String]
    }

    func answerSettings() async throws -> AnswerSettings {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await decoder.decode(AnswerSettings.self, from: request("/answer/settings"))
    }

    /// Store the ChatGPT model/effort choice on the server; it applies to the
    /// running server immediately and survives restarts.
    func updateAnswerSettings(model: String, reasoningEffort: String) async throws {
        _ = try await request(
            "/answer/settings",
            method: "POST",
            jsonBody: ["chatgpt_model": model, "chatgpt_reasoning_effort": reasoningEffort]
        )
    }
}
