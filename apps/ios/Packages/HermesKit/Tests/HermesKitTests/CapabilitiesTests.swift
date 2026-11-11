import Foundation
import HermesBotProfile
import HermesProtocol
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
            ["id": "browser", "label": "Browser", "state": "not_yet_available", "reason": "Coming soon.", "setting": "browser.mode"],
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
        #expect(rows.map(\.state) == [.on, .off, .unavailable, .on, .notYetAvailable, .unavailable])
        #expect(rows[1].keyName == "EXA_API_KEY")
        #expect(rows[4].setting == "browser.mode")
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

    @Test("indicator and state word separate on, limited, off, unavailable and not yet available")
    func display() async throws {
        let rows = try await rows()
        #expect(rows.map(\.indicator) == [.on, .off, .unavailable, .limited, .notYetAvailable, .unavailable])
        #expect(rows.map(\.stateWord) == ["On", "Off", "Unavailable", "Limited", "Coming soon", "Unavailable"])
    }

    @Test("the terminal hint names the key only for an off or limited row that has one")
    func hint() async throws {
        let rows = try await rows()
        #expect(rows[0].terminalHint == nil)
        #expect(rows[1].terminalHint == "Set EXA_API_KEY from your terminal.")
        #expect(rows[2].terminalHint == nil)
        #expect(rows[3].terminalHint == "Set GOOGLE_MAPS_API_KEY from your terminal.")
        #expect(rows[4].terminalHint == nil)
        #expect(rows[5].terminalHint == nil)
        #expect(rows[1].shownKeyName == "EXA_API_KEY")
        #expect(rows[5].shownKeyName == nil)
    }

    @Test("a gateway failure surfaces as a bots error")
    func failure() async {
        let bots = ScriptedBots()
        await #expect(throws: BotsError.self) {
            try await CapabilitiesService(gateway: bots.gateway).status(profile: "a")
        }
    }
}
