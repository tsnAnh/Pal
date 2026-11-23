import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

@Suite("Provider test backend")
struct ProviderBackendTests {
    private func backend(_ bots: ScriptedBots) -> ModelProvidersBackend {
        ModelProvidersBackend(
            providers: ModelProvidersClient(gateway: bots.gateway, profile: "atlas"), models: BotModelClient(gateway: bots.gateway, profile: "atlas"))
    }

    @Test("saving a staged provider writes the address first, then the key, both to the profile")
    func saveOrder() async {
        let bots = ScriptedBots()
        bots.script("model.providers.set_base_url", ["outcome": "saved"])
        bots.script("model.save_key", ["provider": ["slug": "lmstudio"]])
        let key = "sk-fake-\(UUID().uuidString)"
        let reason = await backend(bots).saveStaged(provider: "lmstudio", apiKey: SecretString(key), baseURL: "http://localhost:1234/v1")
        #expect(reason == nil)
        #expect(bots.calls.map(\.method) == ["model.providers.set_base_url", "model.save_key"])
        #expect(bots.calls[0].params == ["provider": "lmstudio", "base_url": "http://localhost:1234/v1", "profile": "atlas"])
        #expect(bots.calls[1].params == ["slug": "lmstudio", "api_key": .string(key), "profile": "atlas"])
    }

    @Test("only what was staged is written")
    func saveOnlyWhatIsStaged() async {
        let keyOnly = ScriptedBots()
        keyOnly.script("model.save_key", ["provider": [:]])
        #expect(await backend(keyOnly).saveStaged(provider: "openrouter", apiKey: SecretString("k"), baseURL: nil) == nil)
        #expect(keyOnly.calls.map(\.method) == ["model.save_key"])

        let addressOnly = ScriptedBots()
        addressOnly.script("model.providers.set_base_url", ["outcome": "saved"])
        #expect(await backend(addressOnly).saveStaged(provider: "lmstudio", apiKey: nil, baseURL: "http://localhost:1234/v1") == nil)
        #expect(addressOnly.calls.map(\.method) == ["model.providers.set_base_url"])

        let nothing = ScriptedBots()
        #expect(await backend(nothing).saveStaged(provider: "lmstudio", apiKey: SecretString(""), baseURL: "") == nil)
        #expect(nothing.calls.isEmpty)
    }

    @Test("a refused address stops before the key is written, and a refused key says so")
    func saveFailures() async {
        let invalid = ScriptedBots()
        invalid.script("model.providers.set_base_url", ["outcome": "invalid", "reason": "Use an https address."])
        let reason = await backend(invalid).saveStaged(provider: "lmstudio", apiKey: SecretString("k"), baseURL: "ftp://x")
        #expect(reason == "Use an https address.")
        #expect(invalid.calls(to: "model.save_key").isEmpty)

        let keyFailure = ScriptedBots()
        keyFailure.script("model.save_key") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await backend(keyFailure).saveStaged(provider: "openrouter", apiKey: SecretString("k"), baseURL: nil) == ModelProvidersClient.couldNotSaveKey)
    }

    @Test("pinning confirms the model for the profile and maps every outcome to a reason or nothing")
    func pin() async {
        let saved = ScriptedBots()
        saved.script("profiles.configure", ["applied": ["model": true]])
        #expect(await backend(saved).pin(ModelChoice(provider: "openrouter", model: "gpt-5")) == nil)
        #expect(
            saved.calls(to: "profiles.configure").first?.params == [
                "name": "atlas", "provider": "openrouter", "model": "gpt-5", "confirm_expensive_model": true,
            ])

        let notApplied = ScriptedBots()
        notApplied.script("profiles.configure", ["applied": ["model": false]])
        #expect(await backend(notApplied).pin(ModelChoice(provider: "a", model: "b")) == BotModelClient.couldNotSaveModel)

        let confirm = ScriptedBots()
        confirm.script("profiles.configure", ["confirm_required": true, "confirm_message": "That costs more."])
        #expect(await backend(confirm).pin(ModelChoice(provider: "a", model: "b")) == "That costs more.")

        let broken = ScriptedBots()
        broken.script("profiles.configure") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await backend(broken).pin(ModelChoice(provider: "a", model: "b")) == BotModelClient.couldNotSaveModel)
    }

    @Test("remove is true when the credential is gone and false for every refusal")
    func remove() async {
        let expected: [(String, Bool)] = [
            ("removed", true), ("nothing_to_remove", true), ("still_set", false), ("refused", false), ("unsupported", false), ("failed", false),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("model.providers.remove", ["outcome": .string(wire)])
            #expect(await backend(bots).remove(provider: "openai-codex") == result)
        }
    }

    @Test("the test goes through the client with the staged request")
    func runTest() async {
        let bots = ScriptedBots()
        bots.script("model.providers.test", ["ok": true, "provider": "openrouter", "model": "gpt-5", "latency_ms": 90])
        let result = await backend(bots).runTest(ProviderTestRequest(provider: "openrouter", model: "gpt-5", apiKey: SecretString("k")))
        #expect(result.ok && result.latencyMilliseconds == 90)
        #expect(bots.calls(to: "model.providers.test").first?.params["api_key"] == "k")
    }
}
