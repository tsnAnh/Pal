import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol

private let described: JSONValue = [
    "name": "atlas",
    "model": ["provider": "anthropic", "default": "claude-a"],
    "fallback_providers": [["provider": "openrouter", "model": "m1"], ["provider": "openrouter", "model": "m2"]],
]

private let options: JSONValue = [
    "providers": [
        ["slug": "anthropic", "name": "Anthropic", "models": ["claude-a", "claude-b"], "authenticated": true],
        ["slug": "openrouter", "name": "OpenRouter", "models": ["m1", "m2", "m3"], "authenticated": true],
        ["slug": "openai", "name": "OpenAI", "models": ["gpt-x"], "authenticated": false],
    ]
]

private func applied(_ key: String, _ ok: Bool = true) -> JSONValue { ["ok": .bool(ok), "applied": [key: .bool(ok)]] }

@MainActor
@Suite("Bot model picker")
struct BotModelsTests {
    private func make(_ bots: ScriptedBots) -> BotModelsModel {
        BotModelsModel(client: BotModelClient(gateway: bots.gateway, profile: "atlas"), profile: "atlas", surfaces: scratchSurfaces())
    }

    private func loaded(_ bots: ScriptedBots) async -> BotModelsModel {
        bots.script("profiles.describe", described)
        bots.script("model.options", options)
        let model = make(bots)
        await model.load()
        return model
    }

    @Test("load reads the pin, the chain and the catalog for this bot only")
    func loads() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        #expect(model.phase == .ready)
        #expect(model.settings.current == ModelChoice(provider: "anthropic", model: "claude-a"))
        #expect(model.settings.fallbacks.map(\.model) == ["m1", "m2"])
        #expect(bots.calls(to: "profiles.describe").first?.params == ["name": "atlas"])
        #expect(bots.calls(to: "model.options").first?.params == ["profile": "atlas", "include_unconfigured": true])
        #expect(model.usableProviders.map(\.id) == ["anthropic", "openrouter"])
        #expect(model.providersNeedingKey.map(\.id) == ["openai"])
    }

    @Test("search narrows by model or provider and never lists a provider without a key")
    func search() async {
        let model = await loaded(ScriptedBots())
        #expect(model.models(matching: "m3").map(\.id) == ["openrouter"])
        #expect(model.models(matching: "m3").first?.models == ["m3"])
        #expect(model.models(matching: "anth").first?.models == ["claude-a", "claude-b"])
        #expect(model.models(matching: "gpt").isEmpty)
    }

    @Test("choosing a model writes the pin for the bot and keeps the new value")
    func choose() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure", applied("model"))
        await model.choose(ModelChoice(provider: "anthropic", model: "claude-b"))
        #expect(model.settings.current?.model == "claude-b")
        #expect(bots.calls(to: "profiles.configure").first?.params == ["name": "atlas", "provider": "anthropic", "model": "claude-b"])
        if case .saved = model.save {} else { Issue.record("expected saved") }
    }

    @Test("a failed write keeps the old model and says so")
    func chooseFails() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure") { _ in throw ScriptedBots.ScriptError.unscripted("profiles.configure") }
        await model.choose(ModelChoice(provider: "anthropic", model: "claude-b"))
        #expect(model.settings.current?.model == "claude-a")
        #expect(model.save == .failed(BotModelClient.couldNotSaveModel))
    }

    @Test("a guarded model waits for confirmation, then resends with it")
    func confirmation() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure", ["ok": true, "applied": [:], "confirm_required": true, "confirm_message": "Costs more."])
        let pick = ModelChoice(provider: "anthropic", model: "claude-b")
        await model.choose(pick)
        #expect(model.settings.current?.model == "claude-a")
        #expect(model.confirmation == .init(choice: pick, message: "Costs more."))
        bots.script("profiles.configure", applied("model"))
        await model.confirmPending()
        #expect(model.settings.current == pick)
        #expect(bots.calls(to: "profiles.configure").last?.params["confirm_expensive_model"] == true)
    }

    @Test("fallbacks add, reorder and remove as one complete ordered list")
    func fallbacks() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure", applied("fallback_providers"))
        let m3 = ModelChoice(provider: "openrouter", model: "m3")
        await model.addFallback(m3)
        await model.moveFallback(m3, by: -1)
        await model.moveFallback(m3, by: -1)
        await model.removeFallback(ModelChoice(provider: "openrouter", model: "m2"))
        #expect(model.settings.fallbacks.map(\.model) == ["m3", "m1"])
        let sent = bots.calls(to: "profiles.configure").map { $0.params["fallback_providers"]?.arrayValue?.count }
        #expect(sent == [3, 3, 3, 2])
    }

    @Test("a failed fallback write keeps the old list; duplicates and the main model are skipped")
    func fallbackFails() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        await model.addFallback(ModelChoice(provider: "openrouter", model: "m1"))
        await model.addFallback(ModelChoice(provider: "anthropic", model: "claude-a"))
        #expect(bots.calls(to: "profiles.configure").isEmpty)
        bots.script("profiles.configure", applied("fallback_providers", false))
        await model.removeFallback(ModelChoice(provider: "openrouter", model: "m1"))
        #expect(model.settings.fallbacks.map(\.model) == ["m1", "m2"])
        #expect(model.save == .failed(BotModelClient.couldNotSaveFallbacks))
    }
}
