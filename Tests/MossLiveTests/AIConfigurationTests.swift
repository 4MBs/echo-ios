import Foundation
@testable import MossLive
import XCTest

final class AIConfigurationTests: XCTestCase {
    func testDecodesProviderOwnedFastTierID() throws {
        let data = Data(
            #"""
            {
              "provider": "chatgpt",
              "chatgpt_model": "gpt-test",
              "chatgpt_reasoning_effort": "medium",
              "chatgpt_service_tier": "default",
              "chatgpt_models": [{
                "id": "gpt-test",
                "label": "GPT Test",
                "efforts": ["medium", "high"],
                "default_effort": "medium",
                "service_tiers": [{
                  "id": "priority-regional",
                  "label": "Fast",
                  "description": "Lower latency"
                }]
              }],
              "reasoning_efforts": ["medium", "high"]
            }
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let settings = try decoder.decode(BackendAPI.AnswerSettings.self, from: data)

        XCTAssertEqual(settings.chatgptModels[0].serviceTiers?.map(\.id), ["priority-regional"])
    }

    @MainActor
    func testFastSelectionUpdatesImmediatelyAndPersistsExactTier() async throws {
        let recorder = SettingsRecorder()
        let settings = try makeSettings()
        let store = AIConfigurationStore(settings: settings) { updated, _ in
            await recorder.record(updated.chatgptServiceTier)
        }
        let api = BackendAPI(host: "unused.invalid", port: 1, token: "test")

        store.selectServiceTier("priority-regional", api: api)

        XCTAssertEqual(store.settings?.chatgptServiceTier, "priority-regional")
        for _ in 0 ..< 20 {
            if await recorder.value != nil { break }
            await Task.yield()
        }
        let persisted = await recorder.value
        XCTAssertEqual(persisted, "priority-regional")
    }

    /// Antigravity carries the effort in the model's name, so the two pickers
    /// write one string. Getting the join wrong sends `agy` a model it has
    /// never heard of, and every answer fails.
    func testGeminiIdentifierIsAModelAndAnEffort() {
        XCTAssertEqual(GeminiModelIdentifier.split("gemini-3.6-flash-low").family, "gemini-3.6-flash")
        XCTAssertEqual(GeminiModelIdentifier.split("gemini-3.6-flash-low").effort, "low")
        XCTAssertEqual(
            GeminiModelIdentifier.join(family: "gemini-3.6-flash", effort: "high"),
            "gemini-3.6-flash-high"
        )
        // A model listed without an effort keeps its whole name, suffix and all.
        XCTAssertEqual(GeminiModelIdentifier.split("claude-sonnet-4-6").family, "claude-sonnet-4-6")
        XCTAssertEqual(GeminiModelIdentifier.split("claude-sonnet-4-6").effort, "")
        XCTAssertEqual(GeminiModelIdentifier.join(family: "claude-sonnet-4-6", effort: ""), "claude-sonnet-4-6")
    }

    @MainActor
    func testSwitchingGeminiModelKeepsTheChosenEffort() async throws {
        let recorder = SettingsRecorder()
        let store = try AIConfigurationStore(settings: makeGeminiSettings()) { updated, _ in
            await recorder.record(updated.geminiModel)
        }

        store.selectGeminiEffort("high", api: api)
        XCTAssertEqual(store.settings?.geminiModel, "gemini-3.6-flash-high")

        store.selectGeminiModel("gemini-3.1-pro", api: api)

        // Pro is listed at high as well, so switching model does not quietly
        // change how hard it thinks.
        XCTAssertEqual(store.settings?.geminiModel, "gemini-3.1-pro-high")
        let persisted = await eventualValue(recorder)
        XCTAssertEqual(persisted, "gemini-3.1-pro-high")
    }

    /// Pro is listed at low and high only. Asking for the effort it does not
    /// have has to land on one it does, or the identifier names no model.
    @MainActor
    func testSwitchingToAModelWithoutThatEffortFallsBackToItsDefault() throws {
        let store = try AIConfigurationStore(settings: makeGeminiSettings()) { _, _ in }

        store.selectGeminiEffort("medium", api: api)
        store.selectGeminiModel("gemini-3.1-pro", api: api)

        XCTAssertEqual(store.settings?.geminiModel, "gemini-3.1-pro-low")
    }

    /// The efforts offered are the selected model's own, never the other one's.
    @MainActor
    func testGeminiEffortChoicesFollowTheSelectedModel() throws {
        let store = try AIConfigurationStore(settings: makeGeminiSettings()) { _, _ in }
        let settings = try XCTUnwrap(store.settings)

        XCTAssertEqual(store.geminiEffortChoices(for: settings), ["low", "medium", "high"])

        store.selectGeminiModel("gemini-3.1-pro", api: api)
        let switched = try XCTUnwrap(store.settings)
        XCTAssertEqual(store.geminiEffortChoices(for: switched), ["low", "high"])
    }

    /// A model named in the server's config file that its list has never heard
    /// of still has to be the one the picker shows as selected.
    @MainActor
    func testAnUnlistedGeminiModelIsStillOffered() throws {
        let store = try AIConfigurationStore(
            settings: makeGeminiSettings(model: "gemini-4.0-experimental-high")
        ) { _, _ in }
        let settings = try XCTUnwrap(store.settings)

        XCTAssertEqual(store.geminiFamily(for: settings), "gemini-4.0-experimental")
        XCTAssertTrue(
            store.geminiModelChoices(for: settings).contains { $0.id == "gemini-4.0-experimental" }
        )
    }

    private var api: BackendAPI {
        BackendAPI(host: "unused.invalid", port: 1, token: "test")
    }

    private func eventualValue(_ recorder: SettingsRecorder) async -> String? {
        for _ in 0 ..< 20 {
            if await recorder.value != nil { return await recorder.value }
            await Task.yield()
        }
        return await recorder.value
    }

    private func makeGeminiSettings(model: String = "gemini-3.6-flash-low") throws -> BackendAPI.AnswerSettings {
        let data = Data(
            #"""
            {
              "provider": "gemini",
              "chatgpt_model": "",
              "chatgpt_reasoning_effort": "low",
              "chatgpt_service_tier": "default",
              "chatgpt_models": [],
              "reasoning_efforts": ["low"],
              "gemini_model": "MODEL",
              "gemini_models": [
                {
                  "id": "gemini-3.6-flash",
                  "label": "Gemini 3.6 Flash",
                  "efforts": ["low", "medium", "high"],
                  "default_effort": "low"
                },
                {
                  "id": "gemini-3.1-pro",
                  "label": "Gemini 3.1 Pro",
                  "efforts": ["low", "high"],
                  "default_effort": "low"
                }
              ]
            }
            """#.replacingOccurrences(of: "MODEL", with: model).utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BackendAPI.AnswerSettings.self, from: data)
    }

    private func makeSettings() throws -> BackendAPI.AnswerSettings {
        let data = Data(
            #"""
            {
              "provider": "chatgpt",
              "chatgpt_model": "gpt-test",
              "chatgpt_reasoning_effort": "medium",
              "chatgpt_service_tier": "default",
              "chatgpt_models": [{
                "id": "gpt-test",
                "label": "GPT Test",
                "efforts": ["medium"],
                "default_effort": "medium",
                "service_tiers": [{
                  "id": "priority-regional",
                  "label": "Fast",
                  "description": "Lower latency"
                }]
              }],
              "reasoning_efforts": ["medium"]
            }
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BackendAPI.AnswerSettings.self, from: data)
    }
}

private actor SettingsRecorder {
    private(set) var value: String?

    func record(_ value: String?) {
        self.value = value
    }
}
