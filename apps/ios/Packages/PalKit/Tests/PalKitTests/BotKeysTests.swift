import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

private func status(setNames: Set<String> = []) -> JSONValue {
    func key(_ name: String, _ label: String) -> JSONValue {
        ["name": .string(name), "label": .string(label), "is_set": .bool(setNames.contains(name))]
    }
    return [
        "profile": "atlas",
        "groups": [
            ["id": "search", "label": "Search", "keys": [key("EXA_API_KEY", "Exa"), key("FIRECRAWL_API_KEY", "Firecrawl")]],
            ["id": "empty", "label": "Empty", "keys": []],
        ],
    ]
}

private func setResult(_ name: String, isSet: Bool, setNames: Set<String>) -> JSONValue {
    var result = status(setNames: setNames).objectValue ?? [:]
    result["key_name"] = .string(name)
    result["is_set"] = .bool(isSet)
    return .object(result)
}

@Suite("Bot keys service")
struct BotKeysServiceTests {
    @Test("status asks for the profile and decodes groups, labels and set state, dropping empty groups")
    func decoding() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status(setNames: ["EXA_API_KEY"]))
        let groups = try await BotKeysService(gateway: bots.gateway).status(profile: "atlas")
        #expect(bots.calls.first?.method == "bot_keys.status")
        #expect(bots.calls.first?.params == ["profile": "atlas"])
        #expect(groups.map(\.id) == ["search"])
        #expect(groups[0].keys.map(\.name) == ["EXA_API_KEY", "FIRECRAWL_API_KEY"])
        #expect(groups[0].keys.map(\.isSet) == [true, false])
        #expect(groups[0].keys.map(\.statusWord) == ["Set", "Not set"])
    }

    @Test("the value travels only in the set call, and removing sends null")
    func setParams() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status())
        bots.script("bot_keys.set", setResult("EXA_API_KEY", isSet: true, setNames: ["EXA_API_KEY"]))
        bots.script("bot_keys.set", setResult("EXA_API_KEY", isSet: false, setNames: []))
        let service = BotKeysService(gateway: bots.gateway)
        _ = try await service.status(profile: "atlas")
        _ = try await service.setKey("EXA_API_KEY", to: SecretString("test-value"), profile: "atlas")
        _ = try await service.setKey("EXA_API_KEY", to: nil, profile: "atlas")
        #expect(bots.calls(to: "bot_keys.status").first?.params["value"] == nil)
        let sets = bots.calls(to: "bot_keys.set")
        #expect(sets.map(\.params["value"]) == ["test-value", .null])
        #expect(sets.map(\.params["key_name"]) == ["EXA_API_KEY", "EXA_API_KEY"])
        #expect(sets.allSatisfy { $0.params["profile"] == "atlas" })
    }
}

@MainActor
@Suite("Bot keys model")
struct BotKeysModelTests {
    private func model(_ bots: ScriptedBots) -> BotKeysModel {
        BotKeysModel(service: BotKeysService(gateway: bots.gateway), profile: "atlas")
    }

    private func row(_ model: BotKeysModel, _ name: String) throws -> BotKeyRow {
        try #require(model.groups.flatMap(\.keys).first { $0.name == name })
    }

    @Test("load maps set and not set, and a failed first load is reported")
    func load() async throws {
        let failing = ScriptedBots()
        failing.script("bot_keys.status") { _ in throw GatewayTransportError.closed(.normal) }
        let failed = model(failing)
        await failed.load()
        #expect(failed.phase == .failed)

        let bots = ScriptedBots()
        bots.script("bot_keys.status", status(setNames: ["EXA_API_KEY"]))
        let loaded = model(bots)
        await loaded.load()
        #expect(loaded.phase == .ready)
        #expect(try row(loaded, "EXA_API_KEY").isSet)
        #expect(try !row(loaded, "FIRECRAWL_API_KEY").isSet)
    }

    @Test("submit trims, saves, replaces groups from the response and closes the entry")
    func submit() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status())
        bots.script("bot_keys.set", setResult("EXA_API_KEY", isSet: true, setNames: ["EXA_API_KEY"]))
        let model = model(bots)
        await model.load()
        let exa = try row(model, "EXA_API_KEY")
        model.begin(exa)
        await model.submit("  test-value \n")
        #expect(bots.calls(to: "bot_keys.set").first?.params["value"] == "test-value")
        #expect(model.entry == nil && model.entryState == .idle)
        #expect(try row(model, "EXA_API_KEY").isSet)
        #expect(model.notice(exa) == .saved("Key saved."))
        #expect(!"\(model.groups)\(model.notices)\(model.entryState)".contains("test-value"))
    }

    @Test("a failed save keeps the old groups, keeps the entry open and shows plain words")
    func submitFails() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status(setNames: ["EXA_API_KEY"]))
        bots.script("bot_keys.set") { _ in throw GatewayTransportError.closed(.normal) }
        let model = model(bots)
        await model.load()
        let before = model.groups
        model.begin(try row(model, "EXA_API_KEY"))
        await model.submit("test-value")
        #expect(model.groups == before)
        #expect(model.entry != nil)
        guard case .failed(let text) = model.entryState else { Issue.record("expected a failure"); return }
        #expect(!text.contains("test-value"))
        await model.submit("   ")
        #expect(model.entryState == .failed("Paste a key to save."))
        #expect(bots.calls(to: "bot_keys.set").count == 1)
    }

    @Test("remove sends null and reflects the response; a failure keeps the key")
    func remove() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status(setNames: ["EXA_API_KEY"]))
        bots.script("bot_keys.set") { _ in throw GatewayTransportError.closed(.normal) }
        bots.script("bot_keys.set", setResult("EXA_API_KEY", isSet: false, setNames: []))
        let model = model(bots)
        await model.load()
        let exa = try row(model, "EXA_API_KEY")
        await model.remove(exa)
        #expect(try row(model, "EXA_API_KEY").isSet)
        #expect(model.notice(exa) == .failed("Couldn't remove the key. It was kept."))
        await model.remove(exa)
        #expect(try !row(model, "EXA_API_KEY").isSet)
        #expect(model.notice(exa) == .saved("Key removed."))
        #expect(bots.calls(to: "bot_keys.set").map(\.params["value"]) == [.null, .null])
    }

    @Test("removing a key that is not set sends nothing")
    func removeUnset() async throws {
        let bots = ScriptedBots()
        bots.script("bot_keys.status", status())
        let model = model(bots)
        await model.load()
        await model.remove(try row(model, "EXA_API_KEY"))
        #expect(bots.calls(to: "bot_keys.set").isEmpty)
    }
}
