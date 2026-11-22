import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

private let filler = String(repeating: "FAKE", count: 4)
private let fakeSecret = ["xoxe", "xoxp", "1", filler].joined(separator: ".").replacingOccurrences(of: "xoxp.1.", with: "xoxp-1-")
private let fakeRefresh = ["xoxe", "1", filler].joined(separator: "-")
private let fakeAppKey = ["xapp", "1", filler].joined(separator: "-")

private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

func chatProvider(guided: [String] = ["set_icon", "app_level_credential"], credential: Bool = true) throws -> ChatCapabilitiesWire {
    try decode(ChatCapabilitiesWire.self, [
        "provider_id": "slack", "requires_config_credential": credential, "creates_app": true,
        "capabilities": guided.map { ["capability": $0, "mode": "guided"] } + [["capability": "join_public_space", "mode": "automatic"]],
        "identity_policy": ["app_name_max": 35, "display_name_max": 35, "username_max": 21, "avatar_max_bytes": 1_000_000, "avatar_min_px": 512],
    ])
}

func chatState(
    _ step: String, _ revision: Int, action: [String: Any?] = [:], done: [String] = [], error: [String: String]? = nil, bot: String = "pal",
    fallback: [String: Any]? = nil, resume: String? = nil
) throws -> ChatSetupStateWire {
    try decode(
        ChatSetupStateWire.self,
        stateJSON(step, revision, action: action, done: done, error: error, bot: bot, fallback: fallback, resume: resume)
    )
}

private func changed(
    _ step: String, _ revision: Int, action: [String: Any?] = [:], bot: String = "pal"
) throws -> ChatInstallChangedPayload {
    try decode(ChatInstallChangedPayload.self, ["state": stateJSON(step, revision, action: action, bot: bot)])
}

private func stateJSON(
    _ step: String, _ revision: Int, action: [String: Any?] = [:], done: [String] = [], error: [String: String]? = nil, bot: String = "pal",
    fallback: [String: Any]? = nil, resume: String? = nil
) -> [String: Any] {
    let next: [String: Any] = [
        "kind": action["kind"] as? String ?? "none", "action_id": action["action_id"] as? String ?? "none",
        "link": (action["link"] ?? nil) ?? NSNull(), "copy_text": (action["copy_text"] ?? nil) ?? NSNull(),
    ]
    return [
        "bot": bot, "provider_id": "slack", "workspace": "T1", "step": step, "revision": revision,
        "app_id": NSNull(), "installation_id": NSNull(), "manual_steps_done": done, "resume_step": resume ?? NSNull(),
        "next_action": next, "fallback_action": fallback ?? NSNull(), "error": error ?? NSNull(), "updated_at": 1_700_000_000.0,
    ]
}

actor FakeChatInstallClient: ChatInstallClient {
    var capabilities: [ChatCapabilitiesWire]
    var current: ChatInstallStatusResult
    var unsupported = false
    var providersError: ChatInstallClientError?
    var calls: [String] = []
    var advances: [ChatInstallAdvance] = []
    var stored: [String: String] = [:]
    var spaceList: [ChatSpaceRefWire] = []
    var bound: [ChatBindingWire] = []
    var identityResult: ChatIdentityUpdateResult?
    var identityError: ChatInstallClientError?
    var statusError: ChatInstallClientError?

    init(_ capabilities: [ChatCapabilitiesWire], _ state: ChatSetupStateWire) {
        self.capabilities = capabilities
        var result = try! decode(ChatInstallStatusResult.self, ["state": stateJSON("not_started", 0)])
        result.state = state
        current = result
    }

    func set(_ state: ChatSetupStateWire) { current.state = state }
    func setSpaces(_ spaces: [ChatSpaceRefWire], _ bindings: [ChatBindingWire]) { spaceList = spaces; bound = bindings }
    func markUnsupported() { unsupported = true }
    func setInstallation(_ installation: ChatInstallationWire?) { current.installation = installation }
    func failStatus(_ error: ChatInstallClientError) { statusError = error }
    func failProviders(_ error: ChatInstallClientError) { providersError = error }
    func setIdentity(_ result: ChatIdentityUpdateResult?, error: ChatInstallClientError? = nil) { identityResult = result; identityError = error }

    func providers() async throws -> [ChatCapabilitiesWire] {
        calls.append("providers")
        if unsupported { throw ChatInstallClientError.unsupported }
        if let providersError { throw providersError }
        return capabilities
    }
    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult {
        calls.append("status")
        if let statusError { throw statusError }
        return current
    }
    func begin(_ scope: ChatInstallScope) async throws { calls.append("begin") }
    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws { calls.append("advance"); advances.append(advance) }
    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire] { calls.append("spaces"); return spaceList }
    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult {
        calls.append("join")
        return try decode(ChatSpaceJoinResult.self, [
            "outcome": "needs_invite",
            "next_action": ["kind": "copy_text", "action_id": "invite", "copy_text": "/invite @pal", "link": "https://app.slack.com/client/T1/\(spaceId)"],
        ])
    }
    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire] { calls.append("bindings"); return bound }
    func revoke(_ scope: ChatInstallScope) async throws { calls.append("revoke") }
    func setIcon(_ scope: ChatInstallScope, png: Data) async throws {}
    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult {
        calls.append("updateIdentity")
        if let identityError { throw identityError }
        return try #require(identityResult)
    }
    func storeSecret(label: String, value: String) async throws -> String {
        let id = "vault-\(stored.count + 1)"
        stored[id] = value
        return id
    }
}

@MainActor
@Suite("Chat install model")
struct ChatInstallModelTests {
    static let wireFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/chat-provider/wire.json")

    private func model(_ initial: ChatSetupStateWire, caps: ChatCapabilitiesWire? = nil) async throws -> (ChatInstallModel, FakeChatInstallClient) {
        let client = FakeChatInstallClient([try caps ?? chatProvider()], initial)
        let model = ChatInstallModel(botName: "pal", preferredProvider: "slack", client: client)
        await model.load()
        return (model, client)
    }

    @Test func eachStepMapsToItsScreenAndPrimaryAction() async throws {
        let allow = "https://slack.com/oauth/v2/authorize?client_id=1"
        let cases: [(ChatSetupStateWire, ChatInstallScreen, ChatInstallAction?)] = [
            (try chatState("not_started", 0), .intro(again: false), .begin),
            (try chatState("needs_credential", 1, action: ["kind": "paste_credential", "action_id": "config_credential"]), .credential, .saveCredential),
            (try chatState("creating_app", 2), .setup(task: nil), nil),
            (try chatState("needs_manual_step", 3, action: ["kind": "button", "action_id": "set_icon"]), .setup(task: .setIcon), .markDone(.setIcon)),
            (try chatState("needs_allow", 5, action: ["kind": "open_link", "action_id": "allow", "link": allow]), .allow(URL(string: allow)), .openAllow(URL(string: allow)!)),
            (try chatState("installing", 6), .setup(task: nil), nil),
            (try chatState("ready", 7), .ready, nil),
            (try chatState("revoked", 8), .intro(again: true), .begin),
            (try chatState("error", 4, action: ["kind": "button", "action_id": "retry"], error: ["code": "app_create_failed", "fix": "retry"]),
             .error(.appCreateFailed, fix: .retry), .fix(.retry)),
        ]
        for (snapshot, screen, action) in cases {
            let (model, _) = try await model(snapshot)
            #expect(model.screen == screen, "\(snapshot.step)")
            #expect(model.primaryAction == action, "\(snapshot.step)")
        }
    }

    @Test func pythonFixtureReadyStateLandsOnReady() async throws {
        struct Shape: Decodable { var ChatInstallStatusResult: PalProtocol.ChatInstallStatusResult; var ChatProviderListResult: PalProtocol.ChatProviderListResult }
        let shapes = try JSONDecoder().decode([String: Shape].self, from: Data(contentsOf: Self.wireFixture))
        for (id, shape) in shapes {
            let client = FakeChatInstallClient(shape.ChatProviderListResult.providers, shape.ChatInstallStatusResult.state)
            let model = ChatInstallModel(botName: "pal", preferredProvider: id, client: client)
            await model.load()
            #expect(model.screen == .ready, "\(id)")
            #expect(model.secondaryActions == [.disconnect])
        }
    }

    @Test func eventsApplyByRevisionDroppingStaleAndDuplicateAndRereadingOnGap() async throws {
        let (model, client) = try await model(try chatState("creating_app", 2))
        await model.receive(try changed("needs_credential", 1))
        await model.receive(try changed("needs_allow", 2))
        #expect(model.state?.step == .creatingApp)
        await model.receive(try changed("needs_manual_step", 3, action: ["kind": "button", "action_id": "set_icon"]))
        #expect(model.screen == .setup(task: .setIcon))
        let statusReads = await client.calls.filter { $0 == "status" }.count
        await client.set(try chatState("needs_allow", 6, action: ["kind": "open_link", "action_id": "allow", "link": "https://slack.com/a"]))
        await model.receive(try changed("installing", 7))
        #expect(await client.calls.filter { $0 == "status" }.count == statusReads + 1)
        #expect(model.state?.revision == 6)
        await model.receive(try changed("ready", 4, bot: "other"))
        #expect(model.state?.revision == 6)
    }

    @Test func resumeFromAnotherDeviceSnapshotLandsOnSameStep() async throws {
        let midFlow = try chatState("needs_manual_step", 4, action: ["kind": "button", "action_id": "app_level_credential"], done: ["set_icon"])
        let (mac, _) = try await model(midFlow)
        let (phone, _) = try await model(midFlow)
        #expect(mac.screen == phone.screen)
        #expect(phone.screen == .setup(task: .appLevelCredential))
        let items = phone.checklist
        #expect(items.map(\.status) == [.done, .done, .done, .active, .pending, .pending])
    }

    @Test func errorShowsItsFixAndFixSendsRetry() async throws {
        let failed = try chatState("error", 3, action: ["kind": "button", "action_id": "reenter_credential"], error: ["code": "credential_expired", "fix": "reenter_credential"])
        let (model, client) = try await model(failed)
        #expect(model.primaryAction == .fix(.reenterCredential))
        await client.set(try chatState("needs_credential", 4, action: ["kind": "paste_credential", "action_id": "config_credential"]))
        await model.fix()
        #expect(await client.advances.map(\.event) == [.retry])
        #expect(await client.advances.first?.expectedRevision == 3)
        #expect(model.screen == .credential)
    }

    @Test func secondBotInSameWorkspaceSkipsCredential() async throws {
        let (model, client) = try await model(try chatState("not_started", 0))
        await client.set(try chatState("creating_app", 1))
        await model.begin()
        #expect(model.screen == .setup(task: nil))
        #expect(model.checklist.first?.kind == .workspace)
        #expect(model.checklist.first?.status == .done)
        #expect(await client.stored.isEmpty)
    }

    @Test func credentialGoesToVaultAndOnlyTheVaultIdCrossesTheWire() async throws {
        let (model, client) = try await model(try chatState("needs_credential", 1, action: ["kind": "paste_credential", "action_id": "config_credential"]))
        await client.set(try chatState("creating_app", 2))
        await model.saveCredential(access: fakeSecret, refresh: fakeRefresh)
        let stored = await client.stored
        #expect(Set(stored.values) == [fakeSecret, fakeRefresh])
        let advance = try #require(await client.advances.first)
        #expect(advance.event == .credentialSaved)
        #expect(advance.vaultItemId.flatMap { stored[$0] } == fakeSecret)
        let visible = [String(reflecting: model.snapshot as Any), String(reflecting: model.screen), String(reflecting: model.checklist),
                       String(reflecting: advance), String(reflecting: model.notice as Any)].joined()
        #expect(!visible.contains("FAKE"))
    }

    @Test func refreshTokenIdIsSentWithCredentialSavedAndOmittedWithoutRefresh() async throws {
        let needs = try chatState("needs_credential", 1, action: ["kind": "paste_credential", "action_id": "config_credential"])
        let (model, client) = try await model(needs)
        await model.saveCredential(access: fakeSecret, refresh: fakeRefresh)
        let stored = await client.stored
        let advance = try #require(await client.advances.first)
        #expect(advance.vaultItemId.flatMap { stored[$0] } == fakeSecret)
        #expect(advance.refreshVaultItemId.flatMap { stored[$0] } == fakeRefresh)
        let (bare, bareClient) = try await self.model(needs)
        await bare.saveCredential(access: fakeSecret, refresh: "")
        #expect(await bareClient.stored.count == 1)
        #expect(await bareClient.advances.first?.refreshVaultItemId == nil)
        let (none, noneClient) = try await self.model(needs)
        await none.saveCredential(access: fakeSecret, refresh: nil)
        #expect(await noneClient.advances.first?.refreshVaultItemId == nil)
    }

    @Test func ownerStepShowsOwnerScreenAndConfirmSendsTrimmedMemberId() async throws {
        let (model, client) = try await model(try chatState("needs_owner", 6, action: ["kind": "enter_text", "action_id": "owner_member_id"]))
        #expect(model.screen == .owner)
        #expect(model.primaryAction == .confirmOwner)
        #expect(model.checklist.first { $0.status == .active }?.kind == .allow)
        await model.confirmOwner("   ")
        #expect(await client.advances.isEmpty)
        await model.confirmOwner("  UFAKE0000\n")
        let advance = try #require(await client.advances.first)
        #expect(advance.event == .ownerConfirmed)
        #expect(advance.ownerMemberId == "UFAKE0000")
        #expect(advance.expectedRevision == 6)
    }

    @Test func confirmOwnerIsIgnoredOutsideNeedsOwner() async throws {
        let (model, client) = try await model(try chatState("needs_allow", 5, action: ["kind": "open_link", "action_id": "allow"]))
        await model.confirmOwner("UFAKE0000")
        #expect(await client.advances.isEmpty)
    }

    @Test func botTokenIsAdoptedOnlyWhenTheGatewayOffersTheFallback() async throws {
        let fallback: [String: Any] = ["kind": "paste_credential", "action_id": "bot_token"]
        let allow: [String: Any?] = ["kind": "open_link", "action_id": "allow", "link": "https://slack.com/a"]
        let (model, client) = try await model(try chatState("needs_allow", 5, action: allow, fallback: fallback))
        #expect(model.offersBotToken)
        await model.adoptBotToken("  fake-token-do-not-use ")
        let stored = await client.stored
        let advance = try #require(await client.advances.first)
        #expect(advance.event == .allowGranted)
        #expect(advance.vaultItemId.flatMap { stored[$0] } == "fake-token-do-not-use")
        #expect(!String(reflecting: advance).contains("fake-token-do-not-use"))
        let (plain, plainClient) = try await self.model(try chatState("needs_allow", 5, action: allow))
        #expect(!plain.offersBotToken)
        await plain.adoptBotToken("fake-token-do-not-use")
        #expect(await plainClient.advances.isEmpty)
        #expect(await plainClient.stored.isEmpty)
        let (wrongStep, wrongClient) = try await self.model(try chatState("ready", 7, fallback: fallback))
        await wrongStep.adoptBotToken("fake-token-do-not-use")
        #expect(await wrongClient.advances.isEmpty)
    }

    @Test func identityUpdateStoresTheResultOnlyWhenReady() async throws {
        let manual = try decode(ChatIdentityUpdateResult.self, [
            "outcome": "needs_manual_avatar",
            "identity": ["app_name": "Pal", "display_name": "Pal", "username": "pal", "avatar_ref": NSNull(), "avatar_bytes": NSNull()],
            "next_action": ["kind": "button", "action_id": "set_icon", "link": "https://api.slack.com/apps/A1/general", "copy_text": NSNull()],
        ])
        let (model, client) = try await model(try chatState("ready", 7))
        await client.setIdentity(manual)
        await model.updateIdentity()
        #expect(model.identityUpdate?.outcome == .needsManualAvatar)
        #expect(model.identityUpdate?.nextAction.actionId == "set_icon")
        #expect(model.notice == nil)
        let (early, earlyClient) = try await self.model(try chatState("needs_allow", 5, action: ["kind": "open_link", "action_id": "allow"]))
        await early.updateIdentity()
        #expect(early.identityUpdate == nil)
        #expect(!(await earlyClient.calls.contains("updateIdentity")))
    }

    @Test func identityUpdateFailureShowsANoticeAndUnsupportedIsNotSaved() async throws {
        let (model, client) = try await model(try chatState("ready", 7))
        await client.setIdentity(nil, error: .unsupported)
        await model.updateIdentity()
        #expect(model.notice == .notSaved)
        #expect(model.identityUpdate == nil)
        await client.setIdentity(nil, error: .offline)
        await model.updateIdentity()
        #expect(model.notice == .offline)
    }

    @Test func appLevelKeyIsStoredAndStepAdvances() async throws {
        let (model, client) = try await model(try chatState("needs_manual_step", 4, action: ["kind": "button", "action_id": "app_level_credential"], done: ["set_icon"]))
        await model.markDone(.appLevelCredential, secret: fakeAppKey)
        let advance = try #require(await client.advances.first)
        #expect(advance.manualStep == .appLevelCredential)
        #expect(advance.vaultItemId != nil)
        #expect(!String(reflecting: advance).contains("FAKE"))
    }

    @Test func privateChannelGetsInviteGuidanceAndGoesLive() async throws {
        let (model, client) = try await model(try chatState("ready", 7))
        let spaces = try decode([ChatSpaceRefWire].self, [
            ["id": "C1", "name": "general", "kind": "public", "joined": false],
            ["id": "G1", "name": "plans", "kind": "private", "joined": false],
        ])
        await client.setSpaces(spaces, [])
        await model.refreshSpaces()
        #expect(model.spaces.map(\.status) == [.available, .needsInvite])
        await model.join("G1")
        #expect(model.spaces.last?.invite?.copyText == "/invite @pal")
        let live = try decode([ChatBindingWire].self, [["bot": "pal", "space_id": "G1", "installation_id": "i1", "live": true]])
        await client.setSpaces(spaces, live)
        await model.refreshSpaces()
        #expect(model.spaces.last?.status == .live)
        #expect(model.spaces.last?.invite == nil)
    }

    @Test func gatewayWithoutChatInstallIsUnsupported() async throws {
        let client = FakeChatInstallClient([try chatProvider()], try chatState("not_started", 0))
        await client.markUnsupported()
        let model = ChatInstallModel(botName: "pal", preferredProvider: "slack", client: client)
        await model.load()
        #expect(model.screen == .unsupported)
    }
}
