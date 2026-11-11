import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

@Suite("Messaging settings")
struct MessagingSettingsTests {
    private func platform(id: String = "telegram", enabled: Bool = true, allowed: [String] = ["42"]) -> JSONValue {
        .object([
            "id": .string(id), "name": .string("Telegram"), "enabled": .bool(enabled), "configured": .bool(true),
            "fields": .array([
                .object(["key": .string("TELEGRAM_ALLOWED_USERS"), "kind": .string("allowlist"), "label": .string("Allowed users"), "values": .array(allowed.map(JSONValue.string))]),
                .object(["key": .string("TELEGRAM_HOME_CHANNEL"), "kind": .string("home_channel"), "label": .string("Home channel"), "values": .array([])]),
                .object(["key": .string("FUTURE_KIND"), "kind": .string("something_new"), "label": .string("New"), "values": .array([])]),
            ]),
            "secrets": .array([.object(["key": .string("TELEGRAM_BOT_TOKEN"), "label": .string("Bot token"), "is_set": .bool(true)])]),
        ])
    }

    @Test("load maps platforms, drops unknown field kinds and shows credentials as set flags only")
    func load() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.settings.get", ["profile": "a", "gateway_running": true, "platforms": .array([platform()])])
        let snapshot = try await MessagingSettingsService(gateway: bots.gateway).load(profile: "a")
        #expect(snapshot.gatewayRunning)
        let telegram = try #require(snapshot.platforms.first)
        #expect(telegram.settings.map(\.key) == ["TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL"])
        #expect(telegram.settings.first?.text == "42")
        #expect(telegram.credentials == [MessagingCredential(key: "TELEGRAM_BOT_TOKEN", label: "Bot token", isSet: true)])
        #expect(bots.calls.first?.params == ["profile": "a"])
    }

    @Test("an empty display name falls back to the raw platform id")
    func nameFallback() async throws {
        let bots = ScriptedBots()
        var row = platform(id: "newchat").objectValue ?? [:]
        row["name"] = .string("")
        bots.script("messaging.settings.get", ["profile": "a", "gateway_running": false, "platforms": .array([.object(row)])])
        let snapshot = try await MessagingSettingsService(gateway: bots.gateway).load(profile: "a")
        #expect(snapshot.platforms.first?.displayName == "newchat")
    }

    @Test("save sends only the given fields and reports restart needed")
    func save() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.settings.update", [
            "profile": "a", "gateway_running": true, "settings": platform(allowed: ["1", "2"]),
            "changed": true, "hot_served": false, "restart_needed": true,
        ])
        let result = try await MessagingSettingsService(gateway: bots.gateway)
            .save(profile: "a", platform: "telegram", enabled: nil, values: ["TELEGRAM_ALLOWED_USERS": ["1", "2"]])
        #expect(result.changed && result.restartNeeded)
        #expect(result.platform.settings.first?.values == ["1", "2"])
        let sent = try #require(bots.calls.first?.params)
        #expect(sent["platform"] == "telegram" && sent["profile"] == "a")
        #expect(sent["enabled"] == nil)
        #expect(sent["fields"] == .object(["TELEGRAM_ALLOWED_USERS": .array(["1", "2"])]))
    }

    @Test("a field-level rejection carries the plain-words reasons per key")
    func rejection() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.settings.update") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4101, message: "Some settings need a change", data: .object([
                "fields": .object(["TELEGRAM_ALLOWED_USERS": "Telegram user IDs are numbers, like 123456789."]),
            ])))
        }
        await #expect(throws: MessagingSettingsError.invalid(fields: ["TELEGRAM_ALLOWED_USERS": "Telegram user IDs are numbers, like 123456789."])) {
            try await MessagingSettingsService(gateway: bots.gateway)
                .save(profile: "a", platform: "telegram", enabled: nil, values: ["TELEGRAM_ALLOWED_USERS": ["x"]])
        }
    }

    @Test("a permission refusal surfaces as a bots error, not a field error")
    func permission() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.settings.update") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4003, message: "denied", data: .object(["reason": "permission_denied"])))
        }
        await #expect(throws: BotsError.permissionDenied) {
            try await MessagingSettingsService(gateway: bots.gateway).save(profile: "a", platform: "telegram", enabled: true, values: [:])
        }
    }

    @Test("pasted text splits on commas, spaces and new lines")
    func text() {
        #expect(MessagingSettingsText.values("1, 2;3\n 4  ,") == ["1", "2", "3", "4"])
        #expect(MessagingSettingsText.values("   ").isEmpty)
    }
}
