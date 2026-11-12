import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private let described: JSONValue = ["name": "atlas", "model": ["provider": "anthropic", "default": "claude-a"]]

private func catalog(_ capability: JSONValue?) -> JSONValue {
    var provider: [String: JSONValue] = ["slug": "anthropic", "name": "Anthropic", "models": ["claude-a"], "authenticated": true]
    if let capability { provider["capabilities"] = ["claude-a": capability] }
    return ["providers": [.object(provider)]]
}

@MainActor
@Suite("Bot reasoning effort")
struct BotEffortTests {
    private func loaded(_ bots: ScriptedBots, effort: JSONValue = ["value": "medium"], capability: JSONValue? = ["reasoning": true]) async -> BotModelsModel {
        bots.script("profiles.describe", described)
        bots.script("model.options", catalog(capability))
        bots.script("config.get", effort)
        let model = BotModelsModel(client: BotModelClient(gateway: bots.gateway, profile: "atlas"))
        await model.load()
        return model
    }

    @Test("load reads the bot's own effort through config.get")
    func reads() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        #expect(model.effort == "medium")
        #expect(bots.calls(to: "config.get").first?.params == ["profile": "atlas", "key": "reasoning"])
    }

    @Test("an effort the gateway does not report is unknown, never guessed")
    func unreported() async {
        let model = await loaded(ScriptedBots(), effort: [:])
        #expect(model.effort == nil)
        #expect(ReasoningEffort.title(model.effort) == "unknown")
    }

    @Test("choosing an effort writes it for this bot and keeps the new value")
    func saves() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("config.set", ["key": "reasoning", "value": "high"])
        await model.chooseEffort("high")
        #expect(model.effort == "high")
        let call = bots.calls(to: "config.set").first
        #expect(call?.params == ["profile": "atlas", "key": "reasoning", "value": "high", "scope": "global"])
        guard case .saved = model.save else { Issue.record("expected saved"); return }
    }

    @Test("a refused effort keeps the old value and says it failed")
    func refused() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("config.set") { _ in throw GatewayTransportError.rpc(RPCError(code: 4002, message: "unknown reasoning value")) }
        await model.chooseEffort("high")
        #expect(model.effort == "medium")
        #expect(model.save == .failed(BotModelClient.couldNotSaveEffort))
    }

    @Test("a reply that does not echo the value counts as failed")
    func mismatch() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("config.set", ["key": "reasoning", "value": "low"])
        await model.chooseEffort("high")
        #expect(model.effort == "medium")
    }

    @Test("options follow the model's capability: levels, unsupported or unknown")
    func options() async {
        let on = await loaded(ScriptedBots(), capability: ["reasoning": true, "can_disable_reasoning": true])
        #expect(on.effortOptions == .levels(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]))
        let fixed = await loaded(ScriptedBots(), capability: ["reasoning": true, "can_disable_reasoning": false])
        #expect(fixed.effortOptions == .levels(["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]))
        let off = await loaded(ScriptedBots(), capability: ["reasoning": false])
        #expect(off.effortOptions == .unsupported)
        let silent = await loaded(ScriptedBots(), capability: nil)
        #expect(silent.effortOptions == .unknown)
    }

    @Test("a cloud effort above the cap is shown as reported with a label")
    func cloudCap() {
        #expect(ReasoningEffort.cloudTitle("high") == "High")
        #expect(ReasoningEffort.cloudTitle("xhigh") == "Xhigh (above the allowed cap)")
        #expect(ReasoningEffort.cloudTitle("max") == "Max (above the allowed cap)")
        #expect(ReasoningEffort.cloudTitle(nil) == "unknown")
        #expect(BotModelReading(model: nil, effort: "max").cloudEffortText.contains("above the allowed cap"))
    }
}

@MainActor
@Suite("All bots models")
struct BotModelsOverviewTests {
    @Test("one bot failing shows unknown for that bot only")
    func isolation() async {
        let bots = ScriptedBots()
        bots.script("profiles.list", [
            "profiles": [
                ["name": "atlas", "display_name": "Atlas", "model": "claude-a"],
                ["name": "nova", "model": "", "api_key": "canary-key-1234"],
                ["name": "odd", "model": 7],
            ]
        ])
        bots.script("config.get") { params in
            if params["profile"] == "nova" { throw GatewayTransportError.rpc(RPCError(code: 5000, message: "boom")) }
            return ["value": "high"]
        }
        let model = BotModelsOverviewModel(client: BotModelsOverviewClient(gateway: bots.gateway))
        await model.load()
        #expect(model.phase == .ready)
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0) })
        #expect(rows["atlas"]?.displayName == "Atlas")
        #expect(rows["atlas"]?.chat == BotModelReading(model: "claude-a", effort: "high"))
        #expect(rows["nova"]?.chat.modelText == "unknown")
        #expect(rows["nova"]?.chat.effortText == "unknown")
        #expect(rows["odd"]?.chat.modelText == "unknown")
        #expect(model.rows.allSatisfy { $0.cloud == nil })
        #expect(!String(describing: model.rows).contains("canary-key-1234"))
    }

    @Test("a failing list leaves the screen failed and a later success recovers")
    func listFailure() async {
        let bots = ScriptedBots()
        bots.script("profiles.list") { _ in throw GatewayTransportError.rpc(RPCError(code: 5000, message: "down")) }
        bots.script("profiles.list", ["profiles": [["name": "atlas"]]])
        bots.script("config.get", ["value": "low"])
        let model = BotModelsOverviewModel(client: BotModelsOverviewClient(gateway: bots.gateway))
        await model.load()
        #expect(model.phase == .failed)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.rows.first?.chat.effort == "low")
    }
}
