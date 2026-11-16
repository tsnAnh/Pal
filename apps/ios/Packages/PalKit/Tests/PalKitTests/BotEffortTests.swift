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
        let model = BotModelsModel(client: BotModelClient(gateway: bots.gateway, profile: "atlas"), profile: "atlas", surfaces: scratchSurfaces())
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

    @Test("only the efforts the gateway reports are offered, with Off only when the model can disable reasoning")
    func options() async {
        let on = await loaded(ScriptedBots(), capability: ["reasoning": true, "can_disable_reasoning": true, "efforts": ["low", "high"]])
        #expect(on.effortOptions == .levels(["none", "low", "high"]))
        let fixed = await loaded(ScriptedBots(), capability: ["reasoning": true, "can_disable_reasoning": false, "efforts": ["none", "low", "high"]])
        #expect(fixed.effortOptions == .levels(["low", "high"]))
        let off = await loaded(ScriptedBots(), capability: ["reasoning": false, "efforts": ["low"]])
        #expect(off.effortOptions == .unsupported)
        let silent = await loaded(ScriptedBots(), capability: nil)
        #expect(silent.effortOptions == .unknown)
    }

    @Test("a model with no reported list is unknown and read-only, never a guessed ladder")
    func unreportedList() async {
        for capability: JSONValue in [
            ["reasoning": true],
            ["reasoning": true, "can_disable_reasoning": true],
            ["reasoning": true, "efforts": []],
            ["reasoning": true, "efforts": "high"],
            ["reasoning": true, "efforts": [1, 2]],
            ["reasoning": true, "efforts": ["", "  "]],
            ["reasoning": true, "efforts": ["none"], "can_disable_reasoning": false],
        ] {
            let model = await loaded(ScriptedBots(), capability: capability)
            #expect(model.effortOptions == .unknown)
            #expect(model.effortChoices == nil)
        }
        let nothing = await loaded(ScriptedBots(), effort: [:], capability: ["reasoning": true])
        #expect(ReasoningEffort.title(nothing.effort) == "unknown")
    }

    @Test("a stored effort outside the reported list stays selected and visible")
    func storedOutsideList() async {
        let model = await loaded(ScriptedBots(), effort: ["value": "xhigh"], capability: ["reasoning": true, "efforts": ["low", "high"]])
        #expect(model.effort == "xhigh")
        #expect(model.effortChoices == ["low", "high", "xhigh"])
        let inside = await loaded(ScriptedBots(), effort: ["value": "high"], capability: ["reasoning": true, "efforts": ["low", "high"]])
        #expect(inside.effortChoices == ["low", "high"])
        let off = await loaded(ScriptedBots(), effort: ["value": "none"], capability: ["reasoning": true, "efforts": ["low"]])
        #expect(off.effortChoices == ["low", "none"])
    }

    @Test("an older gateway payload without efforts decodes as before and extra keys are tolerated")
    func decoding() throws {
        let oldPayload: JSONValue = ["reasoning": true, "can_disable_reasoning": false]
        let old = try oldPayload.decoded(as: ModelCapability.self)
        #expect(old == ModelCapability(reasoning: true, canDisableReasoning: false))
        #expect(old.efforts == nil)
        let newerPayload: JSONValue = ["reasoning": true, "efforts": ["low", "low", " high "], "future": ["nested": [1, 2]]]
        let newer = try newerPayload.decoded(as: ModelCapability.self)
        #expect(newer.efforts == ["low", "high"])
        let providerPayload: JSONValue = [
            "slug": "anthropic", "models": ["a"], "capabilities": ["a": ["efforts": ["low"], "extra": true], "b": 7],
        ]
        let provider = try providerPayload.decoded(as: ModelCatalogProvider.self)
        #expect(provider.capabilities["a"]?.efforts == ["low"])
    }

    @Test("a canary in a refused effort write or a failed catalog never reaches the surfaced text")
    func canary() async {
        let bots = ScriptedBots()
        let model = await loaded(bots, capability: ["reasoning": true, "efforts": ["low", "high"]])
        bots.script("config.set") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4002, message: "canary-effort-9f3", data: ["reason": "canary_effort_9f3", "detail": "canary-effort-9f3"]))
        }
        await model.chooseEffort("high")
        #expect(model.save == .failed(BotModelClient.couldNotSaveEffort))
        let broken = ScriptedBots()
        broken.script("profiles.describe", described)
        broken.script("model.options") { _ in throw GatewayTransportError.rpc(RPCError(code: 5000, message: "canary-effort-9f3")) }
        broken.script("config.get", ["value": "high", "canary": "canary-effort-9f3"])
        let degraded = BotModelsModel(client: BotModelClient(gateway: broken.gateway, profile: "atlas"), profile: "atlas", surfaces: scratchSurfaces())
        await degraded.load()
        let surfaced = "\(model.save) \(model.effortOptions) \(degraded.effortOptions) \(degraded.effort ?? "") \(degraded.save)"
        #expect(!surfaced.contains("canary-effort"))
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
        let model = BotModelsOverviewModel(client: BotModelsOverviewClient(gateway: bots.gateway), surfaces: scratchSurfaces())
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
        let model = BotModelsOverviewModel(client: BotModelsOverviewClient(gateway: bots.gateway), surfaces: scratchSurfaces())
        await model.load()
        #expect(model.phase == .failed)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.rows.first?.chat.effort == "low")
    }
}
