import Foundation
import PalBotProfile
import PalConnect
import PalProtocol
import PalTransport
import Testing

@testable import Pal

private func decoded<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

private func slackState(_ step: String, _ revision: Int) -> [String: Any] {
    [
        "bot": "ada", "provider_id": "slack", "workspace": "", "step": step, "revision": revision,
        "app_id": NSNull(), "installation_id": NSNull(), "manual_steps_done": [String](), "resume_step": NSNull(),
        "next_action": ["kind": "none", "action_id": "none", "link": NSNull(), "copy_text": NSNull()],
        "fallback_action": NSNull(), "error": NSNull(), "updated_at": 0,
    ]
}

private actor SlackGateway: ChatInstallClient {
    private var step: String
    private var revision = 0
    private(set) var begins = 0

    init(_ step: String) { self.step = step }

    func move(to step: String) {
        self.step = step
        revision += 1
    }

    func providers() throws -> [ChatCapabilitiesWire] {
        [try decoded(ChatCapabilitiesWire.self, [
            "provider_id": "slack", "requires_config_credential": false, "creates_app": true,
            "capabilities": [["capability": "join_public_space", "mode": "automatic"]],
            "identity_policy": ["app_name_max": 35, "display_name_max": 35, "username_max": 21, "avatar_max_bytes": 1_000_000, "avatar_min_px": 512],
        ])]
    }

    func status(_ scope: ChatInstallScope) throws -> ChatInstallStatusResult {
        try decoded(ChatInstallStatusResult.self, ["state": slackState(step, revision), "installation": NSNull()])
    }

    func begin(_ scope: ChatInstallScope) { begins += 1 }
    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) {}
    func spaces(_ scope: ChatInstallScope) -> [ChatSpaceRefWire] { [] }
    func join(_ scope: ChatInstallScope, spaceId: String) throws -> ChatSpaceJoinResult { throw ChatInstallClientError.unsupported }
    func bindings(_ scope: ChatInstallScope) -> [ChatBindingWire] { [] }
    func revoke(_ scope: ChatInstallScope) {}
    func updateIdentity(_ scope: ChatInstallScope) throws -> ChatIdentityUpdateResult { throw ChatInstallClientError.unsupported }
    func setIcon(_ scope: ChatInstallScope, png: Data) {}
    func storeSecret(label: String, value: String) throws -> String { throw ChatInstallClientError.unsupported }
    func reconnect(_ scope: ChatInstallScope) throws -> ChatInstallStatusResult { throw ChatInstallClientError.unsupported }
}

private struct NoMembers: ChatMemberClient {
    func audience(_ scope: ChatInstallScope) async throws -> ChatAudienceWire { throw ChatInstallClientError.unsupported }
    func setAudience(_ scope: ChatInstallScope, _ change: ChatAudienceChange) async throws -> ChatAudienceWire {
        throw ChatInstallClientError.unsupported
    }
    func people(_ scope: ChatInstallScope, query: String, cursor: String?) async throws -> ChatPeoplePageWire {
        throw ChatInstallClientError.unsupported
    }
    func report(_ scope: ChatInstallScope) async throws -> ChatReportDestinationWire { throw ChatInstallClientError.unsupported }
    func setReport(_ scope: ChatInstallScope, _ destination: ChatReportDestinationWire) async throws -> ChatReportDestinationWire {
        throw ChatInstallClientError.unsupported
    }
    func leave(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceLeaveOutcome { throw ChatInstallClientError.unsupported }
    func desk() async throws -> [ChatDeskItemWire] { [] }
    func decide(itemId: String, choice: ChatDeskChoice, expectedRevision: Int) async throws -> ChatDeskItemWire {
        throw ChatInstallClientError.unsupported
    }
}

@MainActor
private func wizard(_ gateway: SlackGateway) -> SlackSetupModel {
    SlackSetupModel(
        botName: "ada", displayName: "Ada", spec: nil, client: gateway, members: NoMembers(),
        limits: SetupLimits(call: .milliseconds(200), step: .milliseconds(300))
    )
}

@MainActor
private func failure(of model: SlackSetupModel) async throws -> SetupStatus? {
    for _ in 0..<100 where model.flow.engine.failure == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    return model.flow.engine.failure
}

@Suite("Slack setup waits")
@MainActor
struct SlackSetupModelTests {
    @Test func aBotWhoseSlackIsAlreadyLiveOpensAsConnectedAndNeverStartsSetup() async {
        let gateway = SlackGateway("ready")
        let model = wizard(gateway)
        await model.load()
        #expect(model.stage == .linked)
        #expect(await gateway.begins == 0)
    }

    @Test(arguments: [("creating_app", SlackSetupPlan.creatingID), ("installing", SlackSetupPlan.installingID)])
    func aStepThatHearsNothingEndsInAPlainErrorWithRetry(state: String, step: String) async throws {
        let model = wizard(SlackGateway(state))
        await model.load()
        let status = try await failure(of: model)
        #expect(status == .tookTooLong)
        #expect(model.flow.engine.current.id == step)
    }

    @Test func waitingForAllowEndsInAPlainError() async throws {
        let model = wizard(SlackGateway("needs_allow"))
        await model.load()
        await model.flow.performPrimary()
        #expect(model.flow.engine.failure == .tookTooLong)
        #expect(model.flow.engine.current.id == SlackSetupPlan.allowID)
    }

    @Test func retryAfterTheWaitReadsTheGatewayAndMovesOn() async throws {
        let gateway = SlackGateway("installing")
        let model = wizard(gateway)
        await model.load()
        let status = try #require(try await failure(of: model))
        await gateway.move(to: "needs_owner")
        await model.flow.recover(from: status)
        #expect(model.flow.engine.current.id == SlackSetupPlan.ownerID)
        #expect(model.flow.engine.failure == nil)
    }

    @Test func aLateAnswerFromTheGatewayClearsTheTimeout() async throws {
        let gateway = SlackGateway("installing")
        let model = wizard(gateway)
        await model.load()
        _ = try #require(try await failure(of: model))
        await gateway.move(to: "needs_owner")
        await model.refresh()
        #expect(model.flow.engine.current.id == SlackSetupPlan.ownerID)
        #expect(model.flow.engine.failure == nil)
    }
}
