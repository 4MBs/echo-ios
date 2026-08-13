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
