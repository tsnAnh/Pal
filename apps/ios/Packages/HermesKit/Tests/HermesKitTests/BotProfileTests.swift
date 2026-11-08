import CryptoKit
import Foundation
import HermesBotProfile
import HermesProtocol
import HermesTransport
import Synchronization
import Testing

@Suite("Bot profile")
struct BotProfileTests {
    private func service(_ bots: ScriptedBots) -> BotProfileService {
        BotProfileService(gateway: bots.gateway)
    }

    @Test("profile row maps primary flag, routines, title and revision")
    func mapsProfile() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(
            profileRow("default", primary: false, routines: 0),
            profileRow("cho-ua", primary: true, routines: 2, meta: ["title": "chó UA", "shape": "blobatar:ua:organic", "color": "#d6264a"], revision: 4, displayName: "cho-ua")
        ))
        let profile = try await service(bots).profile(named: "cho-ua")
        #expect(profile.isPrimary)
        #expect(profile.routinesEnabled == 2)
        #expect(profile.displayName == "chó UA")
        #expect(profile.meta.revision == 4)
        #expect(profile.meta.shape == "blobatar:ua:organic")
        let call = try #require(bots.calls(to: "profiles.list").first)
        #expect(call.params["include_routines"] == .bool(true))
        #expect(call.params["include_sessions"] == .bool(false))
    }

    @Test("unknown profile name is not found")
    func unknownProfile() async {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("default")))
        await #expect(throws: BotsError.notFound) { try await service(bots).profile(named: "ghost") }
    }

    @Test("label falls back from title to display name to a humanised slug")
    func labels() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(
            profileRow("default"),
            profileRow("market-researcher"),
            profileRow("x", displayName: "Named")
        ))
        let profiles = service(bots)
        #expect(try await profiles.profile(named: "default").displayName == "Hermes")
        #expect(try await profiles.profile(named: "market-researcher").displayName == "Market Researcher")
        #expect(try await profiles.profile(named: "x").displayName == "Named")
    }

    @Test("notifications default on and read the per-bot config")
    func notificationsRead() async throws {
        let bots = ScriptedBots()
        bots.script("config.get") { params in
            params["profile"] == "quiet" ? ["value": "off"] : ["value": "on"]
        }
        let profiles = service(bots)
        #expect(try await profiles.notificationsEnabled(for: "quiet") == false)
        #expect(try await profiles.notificationsEnabled(for: "loud") == true)
        let call = try #require(bots.calls(to: "config.get").first)
        #expect(call.params["key"] == "bot_mode.notifications")
    }

    @Test("missing config value reads as on")
    func notificationsMissing() async throws {
        let bots = ScriptedBots()
        bots.script("config.get", [:])
        #expect(try await service(bots).notificationsEnabled(for: "a") == true)
    }

    @Test("setting notifications writes on or off for that bot only")
    func notificationsWrite() async throws {
        let bots = ScriptedBots()
        bots.script("config.set", ["key": "bot_mode.notifications", "value": "off"])
        try await service(bots).setNotifications(false, for: "alpha")
        let call = try #require(bots.calls(to: "config.set").first)
        #expect(call.params == ["key": "bot_mode.notifications", "value": "off", "profile": "alpha"])
    }

    @Test("a refused notification write surfaces as rejected")
    func notificationsRefused() async {
        let bots = ScriptedBots()
        bots.script("config.set") { _ in throw GatewayTransportError.rpc(RPCError(code: 4001, message: "invalid_params")) }
        await #expect(throws: BotsError.rejected(reason: nil)) { try await service(bots).setNotifications(true, for: "a") }
    }

    @Test("make primary calls the canonical pointer move and requires ok")
    func makePrimary() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.set_primary", ["ok": true, "name": "cho-ua"])
        try await service(bots).makePrimary("cho-ua")
        #expect(bots.calls(to: "profiles.set_primary").first?.params == ["name": "cho-ua"])

        let refused = ScriptedBots()
        refused.script("profiles.set_primary", ["ok": false, "name": "cho-ua"])
        await #expect(throws: BotsError.rejected(reason: nil)) { try await service(refused).makePrimary("cho-ua") }
    }

    @Test("permission and not-found refusals are classified")
    func classification() async {
        let denied = ScriptedBots()
        denied.script("profiles.set_primary") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4003, message: "permission_denied"))
        }
        await #expect(throws: BotsError.permissionDenied) { try await service(denied).makePrimary("x") }
        let missing = ScriptedBots()
        missing.script("profiles.set_primary") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4004, message: "refused", data: ["reason": "not_found"]))
        }
        await #expect(throws: BotsError.notFound) { try await service(missing).makePrimary("x") }
    }

    @Test("cancellation is never reclassified")
    func cancellation() async {
        let bots = ScriptedBots()
        bots.script("profiles.set_primary") { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await service(bots).makePrimary("x") }
    }

    @Test("rename merges the title into existing meta with the expected revision")
    func renameMerges() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("cho-ua", meta: ["shape": "boxy", "color": "#fff"], revision: 3)))
        bots.script("profiles.configure", ["ok": true, "applied": ["ui_meta": true, "ui_meta_revisions": ["hermes-bots": 4]]])
        let profile = BotProfile(name: "cho-ua", displayName: "chó UA", isPrimary: false, routinesEnabled: 0, meta: BotMeta())
        try await service(bots).rename(profile, to: "  Ads bot  ")
        let call = try #require(bots.calls(to: "profiles.configure").first)
        #expect(call.params["name"] == "cho-ua")
        #expect(call.params["ui_meta"] == ["hermes-bots": ["shape": "boxy", "color": "#fff", "title": "Ads bot"]])
        #expect(call.params["ui_meta_expected_revisions"] == ["hermes-bots": 3])
        #expect(bots.calls(to: "profiles.rename").isEmpty)
    }

    @Test("renaming the primary bot also updates its display name through profiles.rename")
    func renamePrimary() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("default", primary: true, revision: 1)))
        bots.script("profiles.configure", ["ok": true, "applied": ["ui_meta": true]])
        bots.script("profiles.rename", ["ok": true, "name": "default", "display_name": "Boss"])
        let profile = BotProfile(name: "default", displayName: "Hermes", isPrimary: true, routinesEnabled: 0, meta: BotMeta())
        try await service(bots).rename(profile, to: "Boss")
        #expect(bots.calls(to: "profiles.rename").first?.params == ["name": "default", "new_name": "Boss"])
    }

    @Test("rename rejects empty and over-long names without calling the gateway")
    func renameValidation() async {
        let bots = ScriptedBots()
        let profile = BotProfile(name: "a", displayName: "A", isPrimary: false, routinesEnabled: 0, meta: BotMeta())
        await #expect(throws: BotsError.rejected(reason: "invalid_name")) { try await service(bots).rename(profile, to: "   ") }
        await #expect(throws: BotsError.rejected(reason: "invalid_name")) {
            try await service(bots).rename(profile, to: String(repeating: "x", count: 61))
        }
        #expect(bots.calls.isEmpty)
    }

    @Test("a revision conflict re-reads and retries, then gives up as conflict")
    func conflictRetry() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("a", meta: ["title": "Old"], revision: 1)))
        let attempts = Mutex(0)
        bots.script("profiles.configure") { _ in
            let attempt = attempts.withLock { value -> Int in value += 1; return value }
            if attempt == 1 {
                return ["ok": false, "applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots": ["expected": 1, "actual": 2]]]]
            }
            return ["ok": true, "applied": ["ui_meta": true]]
        }
        try await service(bots).updateLook("a", shape: "blobatar:a:cloud", colorHex: "#10dc69")
        #expect(bots.calls(to: "profiles.configure").count == 2)

        let stubborn = ScriptedBots()
        stubborn.script("profiles.list", profilesList(profileRow("a", revision: 1)))
        stubborn.script("profiles.configure", ["ok": false, "applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots": ["expected": 1, "actual": 9]]]])
        await #expect(throws: BotsError.conflict) {
            try await service(stubborn).updateLook("a", shape: "boxy", colorHex: "#fff")
        }
        #expect(stubborn.calls(to: "profiles.configure").count == BotProfileService.defaultAttempts)
    }

    @Test("look update marks the look custom and keeps unrelated fields")
    func lookUpdate() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("a", meta: ["title": "A", "hidden": false], revision: 7)))
        bots.script("profiles.configure", ["ok": true, "applied": ["ui_meta": true]])
        try await service(bots).updateLook("a", shape: "blobatar:a:sun", colorHex: "#ed0a37")
        let call = try #require(bots.calls(to: "profiles.configure").first)
        #expect(call.params["ui_meta"] == ["hermes-bots": ["title": "A", "hidden": false, "shape": "blobatar:a:sun", "color": "#ed0a37", "custom": true]])
    }

    @Test("an unchanged look writes nothing")
    func lookNoop() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("a", meta: ["shape": "boxy", "color": "#fff", "custom": true], revision: 1)))
        try await service(bots).updateLook("a", shape: "boxy", colorHex: "#fff")
        #expect(bots.calls(to: "profiles.configure").isEmpty)
    }

    @Test("a rejected ui_meta write is reported")
    func lookRejected() async {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow("a", revision: 1)))
        bots.script("profiles.configure", ["ok": false, "applied": ["ui_meta": false]])
        await #expect(throws: BotsError.rejected(reason: nil)) {
            try await service(bots).updateLook("a", shape: "boxy", colorHex: "#fff")
        }
    }

    @Test("computer status text covers every display state")
    func computerStatus() throws {
        func status(supported: Bool = true, installed: Bool = true, running: Bool = false, holder: String? = nil) throws -> ComputerStatus {
            var object: [String: JSONValue] = ["supported": .bool(supported), "installed": .bool(installed), "running": .bool(running)]
            if let holder { object["lease"] = ["holder": .string(holder)] }
            return ComputerStatus(try JSONValue.object(object).decoded(as: DisplayStatusWire.self))
        }
        #expect(try status().text == "Idle")
        #expect(try status(running: true, holder: "agent").text == "Running")
        #expect(try status(running: true, holder: "human").text == "In use")
        #expect(try status(running: true).text == "Running")
        #expect(try status(installed: false).text == "Not set up")
        #expect(try status(supported: false, installed: false, running: true).text == "Unavailable")
    }

    @Test("display status is read for the named bot")
    func displayStatusCall() async throws {
        let bots = ScriptedBots()
        bots.script("display.status", ["profile": "a", "supported": true, "installed": true, "running": false, "lease": ["holder": "agent"]])
        #expect(try await service(bots).computerStatus(for: "a") == .idle)
        #expect(bots.calls(to: "display.status").first?.params == ["profile": "a"])
    }

    private func template(_ bytes: Data, name: String = "bot.hermesbot", size: Int? = nil, sha: String? = nil) -> JSONValue {
        let digest = sha ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ["filename": .string(name), "data": .string(bytes.base64EncodedString()), "size": .int(size ?? bytes.count), "sha256": .string(digest)]
    }

    @Test("template export returns verified bytes under a leaf filename")
    func templateExport() async throws {
        let bots = ScriptedBots()
        let bytes = Data("zip-bytes".utf8)
        bots.script("profiles.template.export", template(bytes, name: "../../etc/Cho UA.hermesbot"))
        let file = try await service(bots).exportTemplate(for: "cho-ua")
        #expect(file.data == bytes)
        #expect(file.filename == "Cho UA.hermesbot")
        #expect(bots.calls(to: "profiles.template.export").first?.params == ["name": "cho-ua"])
    }

    @Test("template with a wrong digest, size, payload or filename is refused")
    func templateIntegrity() async {
        let bytes = Data("zip-bytes".utf8)
        for bad in [
            template(bytes, sha: String(repeating: "0", count: 64)),
            template(bytes, size: bytes.count + 1),
            template(Data(), name: "x.hermesbot"),
            template(bytes, name: ".."),
            ["filename": "x", "data": "%%%", "size": 3, "sha256": "00"],
        ] as [JSONValue] {
            let bots = ScriptedBots()
            bots.script("profiles.template.export", bad)
            await #expect(throws: BotsError.invalidResponse) { try await service(bots).exportTemplate(for: "a") }
        }
    }
}
