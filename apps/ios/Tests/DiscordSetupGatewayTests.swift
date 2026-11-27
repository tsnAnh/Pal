import Foundation
import PalBotProfile
import PalConnect
import PalProtocol
import PalSettings
import Synchronization
import Testing

@testable import Pal

private struct DeadConnectRPC: ConnectRPC {
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue { throw ConnectAppsError.unavailable }
}

private actor ScriptedInstall: ChatInstallClient {
    private var steps: [String]
    private var revision = 0
    private(set) var begins = 0
    private(set) var advances: [ChatInstallAdvance] = []

    init(_ steps: [String]) { self.steps = steps }

    private func move() {
        if steps.count > 1 {
            steps.removeFirst()
            revision += 1
        }
    }

    func status(_ scope: ChatInstallScope) throws -> ChatInstallStatusResult {
        let step = steps[0]
        let error: Any = step == "error" ? ["code": "install_failed", "fix": "retry"] : NSNull()
        let state: [String: Any] = [
            "bot": "ada", "provider_id": "discord", "workspace": "222", "step": step, "revision": revision,
            "app_id": NSNull(), "installation_id": "discord-222-ada", "manual_steps_done": [String](), "resume_step": NSNull(),
            "next_action": ["kind": "none", "action_id": "none", "link": NSNull(), "copy_text": NSNull()],
            "fallback_action": NSNull(), "error": error, "updated_at": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["state": state, "installation": NSNull()])
        return try JSONDecoder().decode(ChatInstallStatusResult.self, from: data)
    }

    func begin(_ scope: ChatInstallScope) {
        begins += 1
        move()
    }

    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) {
        advances.append(advance)
        move()
    }

    func providers() -> [ChatCapabilitiesWire] { [] }
    func spaces(_ scope: ChatInstallScope) -> [ChatSpaceRefWire] { [] }
    func join(_ scope: ChatInstallScope, spaceId: String) throws -> ChatSpaceJoinResult { throw ChatInstallClientError.unsupported }
    func bindings(_ scope: ChatInstallScope) -> [ChatBindingWire] { [] }
    func revoke(_ scope: ChatInstallScope) {}
    func updateIdentity(_ scope: ChatInstallScope) throws -> ChatIdentityUpdateResult { throw ChatInstallClientError.unsupported }
    func setIcon(_ scope: ChatInstallScope, png: Data) {}
    func reconnect(_ scope: ChatInstallScope) throws -> ChatInstallStatusResult { try status(scope) }
    func channelAccess(_ scope: ChatInstallScope) -> [ChatChannelAccessWire] { [] }
    func storeSecret(label: String, value: String) throws -> String { throw ChatInstallClientError.unsupported }
}

private let studio = DiscordGuild(id: "222", name: "Studio")
private let ownerID = "123456789012345678"

private func gateway(_ install: ScriptedInstall) -> DiscordSetupLiveGateway {
    let service = ConnectAppsService(rpc: DeadConnectRPC(), profile: nil, browser: UnavailableAuthorizationBrowser())
    return DiscordSetupLiveGateway(service: service, client: install, spec: nil)
}

@Suite("Discord setup against the gateway")
struct DiscordSetupGatewayTests {
    @Test func aSetupWaitingForTheOwnerAsksForThemInsteadOfFailing() async throws {
        let install = ScriptedInstall(["needs_owner"])
        let outcome = try await gateway(install).install(in: studio)
        #expect(outcome == .needsOwner)
        #expect(await install.begins == 1)
        #expect(await install.advances.isEmpty)
    }

    @Test func theTypedOwnerGoesToTheGatewayAsOwnerMemberId() async throws {
        let install = ScriptedInstall(["needs_owner", "ready"])
        let outcome = try await gateway(install).confirmOwner(ownerID, in: studio)
        #expect(await install.advances == [ChatInstallAdvance(event: .ownerConfirmed, expectedRevision: 0, ownerMemberId: ownerID)])
        #expect(await install.begins == 0)
        #expect(outcome == .installed(DiscordInstalled(guildID: "222", guildName: "Studio")))
    }

    @Test func confirmingAfterAFailedFinishRetriesTheSetup() async throws {
        let install = ScriptedInstall(["error", "ready"])
        let outcome = try await gateway(install).confirmOwner(ownerID, in: studio)
        #expect(await install.advances == [ChatInstallAdvance(event: .retry, expectedRevision: 0)])
        #expect(outcome == .installed(DiscordInstalled(guildID: "222", guildName: "Studio")))
    }

    @Test(arguments: [true, false])
    func theChannelCheckReadsTheLiveStatusAndNeedsItsAnswer(answers: Bool) async throws {
        let asked = Mutex<[JSONValue]>([])
        let vault = SettingsAPI(profile: "ada") { _, _ in .null }
        let client = GatewayChatInstallClient(bot: "ada", call: { method, params in
            asked.withLock { $0.append(.array([.string(method), params ?? .null])) }
            let state: JSONValue = [
                "bot": "ada", "provider_id": "discord", "workspace": "222", "step": "ready", "revision": 1,
                "next_action": ["kind": "none", "action_id": "none"], "updated_at": 0, "manual_steps_done": [],
            ]
            let channels: JSONValue = answers ? [["channel_id": "900", "name": "ada", "access": "cannot_send"]] : .null
            return ["state": state, "channels": channels]
        }, vault: vault)
        let live = DiscordSetupLiveGateway(
            service: ConnectAppsService(rpc: DeadConnectRPC(), profile: nil, browser: UnavailableAuthorizationBrowser()),
            client: client, spec: nil
        )
        if answers {
            let found = try await live.channelAccess(in: studio)
            #expect(found == [ChatChannelAccessWire(channelId: "900", name: "ada", access: .cannotSend)])
        } else {
            await #expect(throws: SetupStatusError.self) { try await live.channelAccess(in: studio) }
        }
        #expect(asked.withLock { $0 } == [["chat.install.status", [
            "profile": "ada", "provider_id": "discord", "workspace": "222", "check_channels": true,
        ]]])
    }

    @Test(arguments: ["installing", "needs_allow", "creating_app", "needs_manual_step", "a_step_from_the_future"])
    func anUnfinishedSetupNeverNamesItsStep(step: String) async throws {
        do {
            _ = try await gateway(ScriptedInstall([step])).install(in: studio)
            Issue.record("expected a failure")
        } catch let error as SetupStatusError {
            #expect(error.status.title == "Discord stopped the setup")
            #expect(error.status.reason == "Discord did not finish the setup. Retry in a moment.")
            #expect(error.status.actionTitle == "Retry")
            #expect(!error.status.detailsText(appBuild: nil).contains(step))
        }
    }
}
