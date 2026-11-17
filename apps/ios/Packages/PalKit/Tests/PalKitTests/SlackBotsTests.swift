import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

private func installation(_ status: String, workspace: String = "Acme Design") throws -> ChatInstallationWire {
    try JSONDecoder().decode(ChatInstallationWire.self, from: JSONSerialization.data(withJSONObject: [
        "id": "I1", "provider_id": "slack", "bot": "pal", "workspace_id": "T1", "workspace_name": workspace, "status": status,
        "created_at": 1_700_000_000.0, "updated_at": 1_700_000_000.0, "vault_item_ids": ["vault-1"],
    ]))
}

private func client(_ step: String = "not_started", installed: String? = nil) async throws -> FakeChatInstallClient {
    let fake = FakeChatInstallClient([try chatProvider()], try chatState(step, 1))
    if let installed { await fake.setInstallation(try installation(installed)) }
    return fake
}

@MainActor
@Suite("Slack bots")
struct SlackBotsTests {
    private func model(_ clients: [(String, FakeChatInstallClient)]) -> SlackBotsModel {
        SlackBotsModel(bots: clients.map { SlackBot(name: $0.0, displayName: $0.0.capitalized, client: $0.1) })
    }

    @Test func noBotWithAnInstallIsNotSetUp() async throws {
        let pal = try await client()
        let scout = try await client("needs_credential")
        let bots = model([("pal", pal), ("scout", scout)])
        await bots.load()
        #expect(bots.phase == .ready)
        #expect(bots.rows.map(\.state) == [.notInstalled, .notInstalled])
        #expect(bots.rows.map(\.state.detail) == ["Not installed", "Not installed"])
        #expect(bots.summary == "Not set up" && bots.installedCount == 0)
    }

    @Test func aConnectedBotNamesItsWorkspaceAndTheRowCountsIt() async throws {
        let pal = try await client("ready", installed: "active")
        let scout = try await client()
        let bots = model([("pal", pal), ("scout", scout)])
        await bots.load()
        #expect(bots.rows[0].state == .connected(workspace: "Acme Design"))
        #expect(bots.rows[0].state.detail == "Connected to Acme Design")
        #expect(bots.rows[1].state == .notInstalled)
        #expect(bots.summary == "Connected for 1 bot")
        #expect(!bots.needsReinstall)
    }

    @Test func twoConnectedBotsReadAsPlural() async throws {
        let pal = try await client("ready", installed: "active")
        let scout = try await client("ready", installed: "active")
        let bots = model([("pal", pal), ("scout", scout)])
        await bots.load()
        #expect(bots.summary == "Connected for 2 bots")
    }

    @Test func aBotThatNeedsANewPermissionAsksForAReinstallAndStaysCounted() async throws {
        let pal = try await client("ready", installed: "needs_reauth")
        let scout = try await client()
        let bots = model([("pal", pal), ("scout", scout)])
        await bots.load()
        #expect(bots.rows[0].state == .needsReinstall(workspace: "Acme Design"))
        #expect(bots.rows[0].state.detail == "Needs reinstall for a new permission")
        #expect(bots.needsReinstall && bots.installedCount == 1)
        #expect(bots.summary == "Connected for 1 bot")
    }

    @Test func aRevokedInstallReadsAsNotInstalled() async throws {
        let pal = try await client("ready", installed: "revoked")
        let bots = model([("pal", pal)])
        await bots.load()
        #expect(bots.rows[0].state == .notInstalled)
    }

    @Test func eachBotIsAskedForItsOwnSlackStatus() async throws {
        let first = try await client()
        let second = try await client()
        await model([("pal", first), ("scout", second)]).load()
        #expect(await first.calls == ["status"])
        #expect(await second.calls == ["status"])
    }

    @Test func whenEveryBotFailsTheListFailsWithTheFirstReason() async throws {
        let offline = try await client()
        await offline.failStatus(.offline)
        let bots = model([("pal", offline)])
        await bots.load()
        #expect(bots.phase == .failed(.offline))
        #expect(bots.summary == "Couldn't check")
    }

    @Test func aFailureKeepsItsTraceForDetails() async throws {
        let fault = GatewayFault.transport("offline", method: "chat.install.status")
        let broken = try await client()
        await broken.failStatus(.faulted(.offline, fault))
        let bots = model([("pal", broken)])
        await bots.load()
        guard case .failed(let error) = bots.phase else {
            Issue.record("expected a failed phase")
            return
        }
        #expect(error.fault == fault)
    }

    @Test func oneBotFailingLeavesTheRestListed() async throws {
        let broken = try await client()
        await broken.failStatus(.failed(.gateway))
        let healthy = try await client("ready", installed: "active")
        let bots = model([("pal", broken), ("scout", healthy)])
        await bots.load()
        #expect(bots.phase == .ready)
        #expect(bots.rows[0].state == .unavailable(.failed(.gateway)))
        #expect(bots.rows[0].state.detail == "Couldn't check")
        #expect(bots.summary == "Connected for 1 bot")
    }

    @Test func anOldGatewayWithoutChatInstallFailsAsUnsupported() async throws {
        let old = try await client()
        await old.failStatus(.unsupported)
        let bots = model([("pal", old)])
        await bots.load()
        #expect(bots.phase == .failed(.unsupported))
    }
}
