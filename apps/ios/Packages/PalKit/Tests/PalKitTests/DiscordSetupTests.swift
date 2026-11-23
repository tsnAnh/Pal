import Foundation
import PalConnect
import PalProtocol
import Testing

private let fakeToken = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"
private let tokenField = SetupField(id: "token", label: "Bot token", secret: true)

@Suite("Discord setup")
struct DiscordSetupTests {
    private let discord = catalogEntry("discord", "Discord", "Communication", method: .botTokenStdio, url: nil)

    @Test func theDiscordMethodAndItsStepKindsDecode() throws {
        let row: JSONValue = [
            "slug": "discord", "name": "Discord", "method": "bot_token_stdio", "status": "not_connected",
            "setup_guide": ["steps": [
                ["id": "token", "kind": "paste", "title": "Paste", "fields": [["id": "token", "label": "Bot token", "secret": true]],
                 "check": "discord_bot"],
                ["id": "servers", "kind": "server_picker", "title": "Servers"],
                ["id": "access", "kind": "access", "title": "Access"],
            ]],
        ]
        let entry = try row.decoded(as: PalCatalogEntry.self)
        #expect(entry.method == .botTokenStdio && entry.method.isSupported)
        #expect(entry.setupGuide?.steps.map(\.kind) == [.paste, .serverPicker, .access])
        #expect(entry.setupGuide?.steps.first?.check == .discordBot)
    }

    @Test func theTokenReachesTheGatewayOnlyAsAVaultItemAndTheItemIsRemovedAfter() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": true, "account": "palbot"] },
            "connectors.discord.token": { _ in ["bot_name": "palbot", "application_id": "101010"] },
        ])
        let service = customService(rpc)
        let step = SetupStep(id: "token", kind: .paste, title: "Paste", fields: [tokenField], check: .discordBot)
        let verification = try await service.verifySetup(discord, step: step, values: ["token": fakeToken])

        #expect(try await service.saveDiscordToken(verification) == "palbot")
        #expect(rpc.params("connectors.discord.token").first?["item"]?.stringValue == "item-1")
        #expect(rpc.params("vault.remove").compactMap { $0["id"]?.stringValue } == ["item-1"])
        let wire = try #require(String(bytes: try JSONEncoder().encode(rpc.params("connectors.discord.token")), encoding: .utf8))
        #expect(!wire.contains(fakeToken))
    }

    @Test func theServerListAndTheSavedChoicesComeFromTheGateway() async throws {
        let rpc = CustomRPC([
            "connectors.discord.guilds": { _ in
                ["guilds": [["id": "111", "name": "Team"], ["id": "222", "name": "Friends"]], "allowed": ["222"], "read_only": false]
            },
        ])
        let servers = try await customService(rpc).discordServers()
        #expect(servers == DiscordServers(
            guilds: [DiscordGuild(id: "111", name: "Team"), DiscordGuild(id: "222", name: "Friends")], allowed: ["222"], readOnly: false
        ))
    }

    @Test func saveSendsTheTickedServersAndTheAccessChoice() async throws {
        let rpc = CustomRPC(["connectors.discord.save": { _ in ["tools": 11, "read_only": true, "guild_ids": ["111", "222"]] }])
        try await customService(rpc).saveDiscord(guildIDs: ["222", "111"], readOnly: true)
        let sent = try #require(rpc.params("connectors.discord.save").first)
        #expect(sent["guild_ids"]?.arrayValue?.compactMap(\.stringValue) == ["111", "222"] && sent["read_only"]?.boolValue == true)
    }

    @Test func aFailedHandshakeKeepsTheGatewayFaultForDetails() async throws {
        let rpc = CustomRPC(["connectors.discord.save": rpcFailure(5034, reason: "CONNECT_FAILED", message: "Discord didn't start on your Pal. Try again.")])
        do {
            try await customService(rpc).saveDiscord(guildIDs: ["111"], readOnly: true)
            Issue.record("expected a failure")
        } catch let error as SetupStatusError {
            #expect(error.status.code == "CONNECT_FAILED" && error.status.method == "connectors.discord.save")
            #expect(error.status.reason == "Discord didn't start on your Pal. Try again." && error.status.trace?.isEmpty == false)
        } catch {
            Issue.record("expected the gateway's refusal, got \(error)")
        }
    }
}
