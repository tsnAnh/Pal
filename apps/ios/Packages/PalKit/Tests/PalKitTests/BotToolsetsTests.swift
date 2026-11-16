import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func described(_ toolsets: JSONValue?, pinned: Bool = true) -> JSONValue {
    var payload: [String: JSONValue] = ["name": "atlas", "toolsets_pinned": .bool(pinned), "future_field": ["x": 1]]
    if let toolsets { payload["toolsets"] = toolsets }
    return .object(payload)
}

private let sample: JSONValue = [
    ["name": "web", "label": "Web", "description": "Search and read pages", "tool_count": 4, "enabled": true],
    ["name": "terminal", "label": "Terminal", "description": "Run commands", "tool_count": 2, "enabled": true],
    ["name": "vision", "label": "Vision", "description": "", "tool_count": 1, "enabled": false],
]

private let canary = "canary-tools-7c1"

private func rpcFailure(_ message: String = canary) -> @Sendable ([String: JSONValue]) throws -> JSONValue {
    { _ in throw GatewayTransportError.rpc(RPCError(code: 5064, message: message, data: ["reason": "canary_tools_7c1", "detail": .string(message)])) }
}

@MainActor
@Suite("Bot toolsets")
struct BotToolsetsTests {
    private func loaded(_ bots: ScriptedBots, toolsets: JSONValue? = sample, pinned: Bool = true) async -> BotToolsetsModel {
        bots.script("profiles.describe", described(toolsets, pinned: pinned))
        let model = BotToolsetsModel(client: BotToolsetsClient(gateway: bots.gateway, profile: "atlas"))
        await model.load()
        return model
    }

    @Test("describe decodes label, description, tool count and enabled state in order")
    func decodes() async {
        let model = await loaded(ScriptedBots())
        #expect(model.phase == .ready)
        #expect(model.items.map(\.name) == ["web", "terminal", "vision"])
        #expect(model.items[0] == Toolset(name: "web", label: "Web", summary: "Search and read pages", toolCount: 4, isEnabled: true))
        #expect(model.isPinned)
        #expect(model.draft == ["web", "terminal"])
        #expect(!model.hasChanges)
    }

    @Test("rows missing optional fields or malformed are tolerated, unusable rows are skipped")
    func tolerant() async {
        let rows: JSONValue = [
            ["name": "web"],
            ["name": "web", "label": "Duplicate"],
            ["label": "No name"],
            "not an object",
            ["name": "files", "label": 5, "tool_count": "many", "enabled": "yes", "extra": [1]],
        ]
        let model = await loaded(ScriptedBots(), toolsets: rows, pinned: false)
        #expect(model.phase == .ready)
        #expect(model.items == [
            Toolset(name: "web", label: "web"),
            Toolset(name: "files", label: "files"),
        ])
        #expect(model.draft.isEmpty)
    }

    @Test("a gateway without the toolsets field shows unavailable, not a failure")
    func olderGateway() async {
        let model = await loaded(ScriptedBots(), toolsets: nil)
        #expect(model.phase == .unavailable)
        #expect(model.items.isEmpty)
        let nulled = await loaded(ScriptedBots(), toolsets: .null)
        #expect(nulled.phase == .unavailable)
    }

    @Test("toggling edits the draft only until saved")
    func toggles() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        model.toggle("vision", on: true)
        model.toggle("web", on: false)
        model.toggle("ghost", on: true)
        #expect(model.draft == ["terminal", "vision"])
        #expect(model.hasChanges && model.canSave)
        #expect(bots.calls(to: "profiles.configure").isEmpty)
    }

    @Test("save sends the full enabled list in display order and keeps the new state")
    func saves() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure", ["ok": true, "applied": ["toolsets": true]])
        model.toggle("vision", on: true)
        model.toggle("terminal", on: false)
        await model.commit()
        let call = bots.calls(to: "profiles.configure").first
        #expect(call?.params == ["name": "atlas", "enabled_toolsets": ["web", "vision"]])
        #expect(model.save == .saved)
        #expect(!model.hasChanges)
        #expect(model.draft == ["web", "vision"])
    }

    @Test("a refused save restores the old state and a retry works")
    func failureRestores() async {
        let bots = ScriptedBots()
        let model = await loaded(bots)
        bots.script("profiles.configure", rpcFailure())
        bots.script("profiles.configure", ["ok": false, "applied": ["toolsets": false]])
        bots.script("profiles.configure", ["ok": true, "applied": ["toolsets": true]])
        model.toggle("vision", on: true)
        await model.commit()
        #expect(model.save == .failed)
        #expect(model.draft == ["web", "terminal"])
        #expect(model.items.filter(\.isEnabled).map(\.name) == ["web", "terminal"])
        model.toggle("vision", on: true)
        await model.commit()
        #expect(model.save == .failed)
        #expect(model.draft == ["web", "terminal"])
        model.toggle("vision", on: true)
        await model.commit()
        #expect(model.save == .saved)
        #expect(model.draft == ["web", "terminal", "vision"])
    }

    @Test("an empty selection is never sent as a pin; the standard set clears it and reloads")
    func standardSet() async {
        let bots = ScriptedBots()
        bots.script("profiles.describe", described(sample))
        bots.script("profiles.describe", described([
            ["name": "web", "label": "Web", "tool_count": 4, "enabled": true],
            ["name": "vision", "label": "Vision", "tool_count": 1, "enabled": true],
        ], pinned: false))
        bots.script("profiles.configure", ["ok": true, "applied": ["toolsets": true]])
        let model = BotToolsetsModel(client: BotToolsetsClient(gateway: bots.gateway, profile: "atlas"))
        await model.load()
        model.toggle("web", on: false)
        model.toggle("terminal", on: false)
        #expect(model.needsSelection && !model.canSave)
        await model.commit()
        #expect(bots.calls(to: "profiles.configure").isEmpty)
        await model.useStandardSet()
        #expect(bots.calls(to: "profiles.configure").first?.params == ["name": "atlas", "enabled_toolsets": []])
        #expect(!model.isPinned)
        #expect(model.draft == ["web", "vision"])
        #expect(model.save == .saved)
    }

    @Test("a failing load shows failed and a later load recovers")
    func loadFailure() async {
        let bots = ScriptedBots()
        bots.script("profiles.describe", rpcFailure())
        bots.script("profiles.describe", described(sample))
        let model = BotToolsetsModel(client: BotToolsetsClient(gateway: bots.gateway, profile: "atlas"))
        await model.load()
        #expect(model.phase == .failed)
        await model.load()
        #expect(model.phase == .ready)
    }

    @Test("a canary in a gateway error or extra field never reaches surfaced state")
    func canaryNotDisclosed() async {
        let bots = ScriptedBots()
        let rows: JSONValue = [
            ["name": "web", "label": "Web", "enabled": true, "api_key": .string(canary)],
            ["name": "files", "label": "Files", "enabled": true],
        ]
        bots.script("profiles.describe", described(rows))
        bots.script("profiles.configure", rpcFailure())
        let model = BotToolsetsModel(client: BotToolsetsClient(gateway: bots.gateway, profile: "atlas"))
        await model.load()
        model.toggle("files", on: false)
        await model.commit()
        #expect(model.save == .failed)
        let broken = ScriptedBots()
        broken.script("profiles.describe", rpcFailure())
        let failedLoad = BotToolsetsModel(client: BotToolsetsClient(gateway: broken.gateway, profile: "atlas"))
        await failedLoad.load()
        #expect(failedLoad.phase == .failed)
        let surfaced = "\(model.phase) \(model.save) \(model.items) \(model.draft) \(failedLoad.phase) \(failedLoad.save) \(failedLoad.items)"
        #expect(!surfaced.contains("canary"))
    }
}
