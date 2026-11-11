import Foundation
import PalBotProfile
import PalProtocol
import Testing

@Suite("Capabilities")
struct CapabilitiesTests {
    private let payload: JSONValue = [
        "profile": "a",
        "capabilities": [
            ["id": "web", "label": "Web search", "state": "on"],
            ["id": "deep_search", "label": "Deep search", "state": "off", "reason": "Needs a search key.", "key_name": "EXA_API_KEY"],
            ["id": "youtube", "label": "YouTube", "state": "unavailable", "reason": "Not installed."],
            ["id": "maps", "label": "Maps", "state": "on", "reason": "OpenStreetMap only.", "key_name": "GOOGLE_MAPS_API_KEY"],
            ["id": "browser", "label": "Browser", "state": "off", "reason": "The browserbase browser provider is selected but its credentials are missing.", "setting": "browser.cloud_provider"],
            ["id": "future", "label": "Future", "state": "someday", "key_name": "FUTURE_KEY"],
        ],
    ]

    private func rows() async throws -> [CapabilityRow] {
        let bots = ScriptedBots()
        bots.script("capabilities.status", payload)
        return try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
    }

    @Test("status asks for the profile and decodes every id and state")
    func decoding() async throws {
        let bots = ScriptedBots()
        bots.script("capabilities.status", payload)
        let rows = try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
        #expect(bots.calls.first?.method == "capabilities.status")
        #expect(bots.calls.first?.params == ["profile": "a"])
        #expect(rows.map(\.id) == ["web", "deep_search", "youtube", "maps", "browser", "future"])
        #expect(rows.map(\.state) == [.on, .off, .unavailable, .on, .off, .unavailable])
        #expect(rows[1].keyName == "EXA_API_KEY")
        #expect(rows[4].setting == "browser.cloud_provider")
        #expect(rows[3].reason == "OpenStreetMap only.")
    }

    @Test("an unknown state falls back to unavailable and a broken row is dropped")
    func fallbacks() async throws {
        let bots = ScriptedBots()
        bots.script("capabilities.status", ["profile": "a", "capabilities": [
            ["id": "web", "label": "Web", "state": "on"],
            ["label": "No id"],
            ["id": "x", "label": "X", "state": 7],
            ["id": "future", "state": "someday"],
        ]])
        let rows = try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
        #expect(rows.map(\.id) == ["web", "future"])
        #expect(rows[1].state == .unavailable)
        #expect(rows[1].label == "future")
    }

    @Test("indicator and state word separate on, limited, off and unavailable")
    func display() async throws {
        let rows = try await rows()
        #expect(rows.map(\.indicator) == [.on, .off, .unavailable, .limited, .off, .unavailable])
        #expect(rows.map(\.stateWord) == ["On", "Off", "Unavailable", "Limited", "Off", "Unavailable"])
    }

    @Test("settable keys name the key only for an off or limited row that has one, or the provider choices")
    func settable() async throws {
        let rows = try await rows()
        #expect(rows.map(\.settableKeys) == [[], ["EXA_API_KEY"], [], ["GOOGLE_MAPS_API_KEY"], [], []])
        #expect(rows[1].shownKeyName == "EXA_API_KEY")
        #expect(rows[5].shownKeyName == nil)
        let web = CapabilityRow(id: "web", label: "Web", state: .off, reason: "No provider.", keyChoices: ["TAVILY_API_KEY", " ", "EXA_API_KEY"])
        #expect(web.settableKeys == ["TAVILY_API_KEY", "EXA_API_KEY"])
        #expect(CapabilityRow(id: "web", label: "Web", state: .on, keyChoices: ["TAVILY_API_KEY"]).settableKeys == [])
    }

    @Test("choices decode from key_choices")
    func choices() async throws {
        let bots = ScriptedBots()
        bots.script("capabilities.status", ["profile": "a", "capabilities": [
            ["id": "web", "label": "Web", "state": "off", "reason": "None.", "key_choices": ["TAVILY_API_KEY", "EXA_API_KEY"]],
        ]])
        let rows = try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
        #expect(rows[0].settableKeys == ["TAVILY_API_KEY", "EXA_API_KEY"])
    }

    @Test("setting a key sends the name and value for the profile and returns the refreshed rows")
    func setKey() async throws {
        let bots = ScriptedBots()
        let canary = "CANARY-\(UUID().uuidString)"
        bots.script("capabilities.set_key", ["profile": "a", "key_name": "GOOGLE_MAPS_API_KEY", "is_set": true, "capabilities": [
            ["id": "maps", "label": "Maps", "state": "on"],
        ]])
        let rows = try await CapabilitiesService(gateway: bots.gateway)
            .setKey("GOOGLE_MAPS_API_KEY", to: SecretString(canary), profile: "a")
        let call = try #require(bots.calls.first)
        #expect(call.method == "capabilities.set_key")
        #expect(call.params == ["profile": "a", "key_name": "GOOGLE_MAPS_API_KEY", "value": .string(canary)])
        #expect(rows.map(\.indicator) == [.on])
        #expect(!String(describing: rows).contains(canary))
    }

    @Test("removing a key sends a null value")
    func removeKey() async throws {
        let bots = ScriptedBots()
        bots.script("capabilities.set_key", ["profile": "a", "key_name": "YOUTUBE_API_KEY", "is_set": false, "capabilities": []])
        _ = try await CapabilitiesService(gateway: bots.gateway).setKey("YOUTUBE_API_KEY", to: nil, profile: "a")
        #expect(bots.calls.first?.params["value"] == JSONValue.null)
    }

    @Test("a refused key surfaces as a bots error and never echoes the value")
    func refusedKey() async {
        let bots = ScriptedBots()
        await #expect(throws: BotsError.self) {
            try await CapabilitiesService(gateway: bots.gateway).setKey("OPENAI_API_KEY", to: SecretString("x"), profile: "a")
        }
    }

    @Test("a gateway failure surfaces as a bots error")
    func failure() async {
        let bots = ScriptedBots()
        await #expect(throws: BotsError.self) {
            try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
        }
    }
}
