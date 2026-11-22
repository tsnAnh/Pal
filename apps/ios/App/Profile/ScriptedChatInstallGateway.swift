import Foundation
import PalBotProfile
import PalProtocol

actor ScriptedChatInstallGateway: ChatInstallClient, ChatMemberClient {
    static let shared = ScriptedChatInstallGateway()
    static let resetArgument = "-hermes-test-chat-install-reset"
    static let failArgument = "-hermes-test-chat-install-fail"
    static let allowLink = "https://slack.com/oauth/v2/authorize?client_id=scripted"
    private static let defaultsKey = "scriptedChatInstall"

    private struct Snapshot: Codable {
        var step = "not_started"
        var revision = 0
        var done: [String] = []
        var joined: [String] = []
        var live: [String] = []
        var invited: [String] = []
        var policy = "owner_only"
        var members: [String] = []
        var includeRestricted = false
        var audienceRevision = 0
        var reportSpace: String?
        var deskState = "open"
        var deskRevision = 0
    }

    static let people: [(id: String, name: String)] = [
        ("U1", "Minh Pham"), ("U2", "Linh Nguyen"), ("U3", "Sarah Chen"), ("U4", "Duc Tran"), ("U5", "An Le"), ("U6", "Priya Raman"),
    ]
    static let redirectAddress = "https://pal.example.test/webapp/chat-install/callback"

    private var snapshot: Snapshot
    private var listeners: [AsyncStream<ChatInstallChangedPayload>.Continuation] = []
    private var deskListeners: [AsyncStream<ChatDeskChangedPayload>.Continuation] = []

    private init() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains(Self.resetArgument) { defaults.removeObject(forKey: Self.defaultsKey) }
        snapshot = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } // perf-lint: ok UI-test-only actor, never on the main actor
            ?? Snapshot()
    }

    nonisolated var source: ChatInstallSource {
        ChatInstallSource(
            client: self, members: self,
            events: { AsyncStream { continuation in Task { await self.listen(continuation) } } },
            deskEvents: { AsyncStream { continuation in Task { await self.listenDesk(continuation) } } }
        )
    }

    private func listenDesk(_ continuation: AsyncStream<ChatDeskChangedPayload>.Continuation) {
        deskListeners.append(continuation)
    }

    private func listen(_ continuation: AsyncStream<ChatInstallChangedPayload>.Continuation) {
        listeners.append(continuation)
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.defaultsKey) // perf-lint: ok UI-test-only actor, never on the main actor
    }

    private func move(_ step: String, done: String? = nil) {
        snapshot.step = step
        snapshot.revision += 1
        if let done { snapshot.done.append(done) }
        persist()
        guard let payload = try? decode(ChatInstallChangedPayload.self, ["state": stateJSON()]) else { return }
        for listener in listeners { listener.yield(payload) }
    }

    private func moveLater(_ step: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            move(step)
        }
    }

    private func stateJSON() -> [String: Any] {
        let action: [String: Any] = switch snapshot.step {
        case "needs_credential": ["kind": "paste_credential", "action_id": "config_credential", "link": NSNull(), "copy_text": NSNull()]
        case "needs_manual_step" where !snapshot.done.contains("set_icon"):
            ["kind": "button", "action_id": "set_icon", "link": "https://api.slack.com/apps/A1/general", "copy_text": NSNull()]
        case "needs_manual_step" where !snapshot.done.contains("app_level_credential"):
            ["kind": "button", "action_id": "app_level_credential", "link": "https://api.slack.com/apps/A1/general", "copy_text": NSNull()]
        case "needs_manual_step":
            ["kind": "button", "action_id": "gateway_redirect", "link": "https://api.slack.com/apps/A1/oauth", "copy_text": Self.redirectAddress]
        case "needs_allow": ["kind": "open_link", "action_id": "allow", "link": Self.allowLink, "copy_text": NSNull()]
        default: ["kind": "none", "action_id": "none", "link": NSNull(), "copy_text": NSNull()]
        }
        return [
            "bot": "default", "provider_id": "slack", "workspace": "T-scripted", "step": snapshot.step, "revision": snapshot.revision,
            "app_id": snapshot.revision > 2 ? "A1" : NSNull(), "installation_id": NSNull(), "manual_steps_done": snapshot.done,
            "resume_step": NSNull(), "next_action": action, "error": NSNull(), "updated_at": 1_700_000_000.0,
        ]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) // perf-lint: ok UI-test-only actor, never on the main actor
    }

    static let refusal = GatewayFault(code: 4403, reason: "owner_only", trace: TraceID("7f3k2m9a")!, method: "chat.provider.list",
                                      source: .gateway, gatewayVersion: "291aaa2b")

    func providers() async throws -> [ChatCapabilitiesWire] {
        if ProcessInfo.processInfo.arguments.contains(Self.failArgument) {
            await FaultStore.shared.record(Self.refusal)
            throw ChatInstallClientError.faulted(.forbidden, Self.refusal)
        }
        return [try decode(ChatCapabilitiesWire.self, [
            "provider_id": "slack", "requires_config_credential": true, "creates_app": true,
            "capabilities": [
                ["capability": "set_icon", "mode": "guided"], ["capability": "app_level_credential", "mode": "guided"],
                ["capability": "gateway_redirect", "mode": "guided"],
                ["capability": "join_public_space", "mode": "automatic"], ["capability": "join_private_space", "mode": "guided"],
            ],
            "identity_policy": ["app_name_max": 35, "display_name_max": 35, "username_max": 21, "avatar_max_bytes": 1_000_000, "avatar_min_px": 512],
        ])]
    }

    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult {
        if snapshot.step == "needs_allow", await allowWasOpened() {
            move("installing")
            moveLater("ready")
        }
        var result: [String: Any] = ["state": stateJSON()]
        if snapshot.step == "ready" {
            result["installation"] = [
                "id": "I1", "provider_id": "slack", "bot": "default", "workspace_id": "T-scripted", "workspace_name": "Acme Design",
                "status": "active", "created_at": 1_700_000_000.0, "updated_at": 1_700_000_000.0, "vault_item_ids": ["vault-scripted"],
            ]
        }
        return try decode(ChatInstallStatusResult.self, result)
    }

    @MainActor
    private func allowWasOpened() -> Bool {
        ExternalLinkRecorder.shared.opened.contains { $0.absoluteString == Self.allowLink }
    }

    func begin(_ scope: ChatInstallScope) async throws {
        guard snapshot.step == "not_started" || snapshot.step == "revoked" else { throw ChatInstallClientError.staleRevision }
        move("needs_credential")
    }

    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws {
        guard advance.expectedRevision == snapshot.revision else { throw ChatInstallClientError.staleRevision }
        switch (snapshot.step, advance.event) {
        case ("needs_credential", .credentialSaved) where advance.vaultItemId != nil:
            move("creating_app")
            moveLater("needs_manual_step")
        case ("needs_manual_step", .manualStepDone):
            guard let step = advance.manualStep?.rawValue else { throw ChatInstallClientError.failed(.gateway) }
            if step == "app_level_credential", advance.vaultItemId == nil { throw ChatInstallClientError.failed(.gateway) }
            let remaining = ["set_icon", "app_level_credential", "gateway_redirect"].filter { !snapshot.done.contains($0) && $0 != step }
            move(remaining.isEmpty ? "needs_allow" : "needs_manual_step", done: step)
        default:
            throw ChatInstallClientError.failed(.gateway)
        }
    }

    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire] {
        try decode([ChatSpaceRefWire].self, [
            ["id": "C1", "name": "general", "kind": "public", "joined": snapshot.joined.contains("C1")],
            ["id": "C2", "name": "design-crit", "kind": "public", "joined": snapshot.joined.contains("C2")],
            ["id": "G1", "name": "launch-plans", "kind": "private", "joined": snapshot.joined.contains("G1")],
        ])
    }

    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult {
        if spaceId.hasPrefix("G") {
            snapshot.invited.append(spaceId)
            return try decode(ChatSpaceJoinResult.self, [
                "outcome": "needs_invite",
                "next_action": ["kind": "copy_text", "action_id": "invite", "copy_text": "/invite @pal", "link": "https://app.slack.com/client/T-scripted/\(spaceId)"],
            ])
        }
        snapshot.joined.append(spaceId)
        snapshot.live.append(spaceId)
        return try decode(ChatSpaceJoinResult.self, ["outcome": "joined", "next_action": ["kind": "none", "action_id": "none", "link": NSNull(), "copy_text": NSNull()]])
    }

    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire] {
        let reported = snapshot.live
        for invited in snapshot.invited where !snapshot.live.contains(invited) {
            snapshot.joined.append(invited)
            snapshot.live.append(invited)
        }
        return try decode([ChatBindingWire].self, reported.map { ["bot": "default", "space_id": $0, "installation_id": "I1", "live": true] })
    }

    func revoke(_ scope: ChatInstallScope) async throws {
        snapshot.joined = []
        snapshot.live = []
        snapshot.invited = []
        move("revoked")
    }

    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult {
        try decode(ChatIdentityUpdateResult.self, [
            "outcome": "updated",
            "identity": ["app_name": "Pal", "display_name": "Pal", "username": "pal", "avatar_ref": NSNull(), "avatar_bytes": NSNull()],
            "next_action": ["kind": "none", "action_id": "none", "link": NSNull(), "copy_text": NSNull()],
        ])
    }

    func setIcon(_ scope: ChatInstallScope, png: Data) async throws {}

    func storeSecret(label: String, value: String) async throws -> String {
        "vault-scripted-\(snapshot.revision)"
    }
}

extension ScriptedChatInstallGateway {
    func audience(_ scope: ChatInstallScope) async throws -> ChatAudienceWire { audienceWire() }

    func setAudience(_ scope: ChatInstallScope, _ change: ChatAudienceChange) async throws -> ChatAudienceWire {
        guard change.expectedRevision == snapshot.audienceRevision else { throw ChatInstallClientError.staleRevision }
        snapshot.policy = change.policy.rawValue
        if let members = change.members { snapshot.members = members }
        if let include = change.includeRestricted { snapshot.includeRestricted = include }
        snapshot.audienceRevision += 1
        persist()
        return audienceWire()
    }

    func people(_ scope: ChatInstallScope, query: String, cursor: String?) async throws -> ChatPeoplePageWire {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let matches = Self.people.filter { wanted.isEmpty || $0.name.localizedCaseInsensitiveContains(wanted) }
        return ChatPeoplePageWire(
            people: matches.map { ChatPersonWire(id: $0.id, name: $0.name.lowercased().replacingOccurrences(of: " ", with: "."), displayName: $0.name) },
            nextCursor: nil
        )
    }

    func report(_ scope: ChatInstallScope) async throws -> ChatReportDestinationWire { reportWire() }

    func setReport(_ scope: ChatInstallScope, _ destination: ChatReportDestinationWire) async throws -> ChatReportDestinationWire {
        if let spaceId = destination.spaceId, !snapshot.live.contains(spaceId) { throw ChatInstallClientError.notJoined }
        snapshot.reportSpace = destination.spaceId
        persist()
        return reportWire()
    }

    func leave(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceLeaveOutcome {
        snapshot.joined.removeAll { $0 == spaceId }
        snapshot.live.removeAll { $0 == spaceId }
        if snapshot.reportSpace == spaceId { snapshot.reportSpace = nil }
        persist()
        return .left
    }

    func desk() async throws -> [ChatDeskItemWire] {
        snapshot.deskState == "open" ? [deskItem()] : []
    }

    func decide(itemId: String, choice: ChatDeskChoice, expectedRevision: Int) async throws -> ChatDeskItemWire {
        guard expectedRevision == snapshot.deskRevision, snapshot.deskState == "open" else { throw ChatInstallClientError.staleRevision }
        snapshot.deskState = choice == .approve ? "done" : "declined"
        snapshot.deskRevision += 1
        persist()
        return deskItem()
    }

    private func audienceWire() -> ChatAudienceWire {
        let members = snapshot.members.compactMap { id in
            Self.people.first { $0.id == id }.map { ChatAudienceMemberWire(id: $0.id, name: $0.name) }
        }
        return ChatAudienceWire(
            policy: ChatAudiencePolicy(rawValue: snapshot.policy) ?? .ownerOnly, members: members,
            includeRestricted: snapshot.includeRestricted, memberTurnsPerHour: 30, revision: snapshot.audienceRevision
        )
    }

    private func reportWire() -> ChatReportDestinationWire {
        guard let id = snapshot.reportSpace else { return .ownerDirectMessages }
        let names = ["C1": "general", "C2": "design-crit", "G1": "launch-plans"]
        return .space(id: id, name: names[id] ?? id)
    }

    private func deskItem() -> ChatDeskItemWire {
        ChatDeskItemWire(
            id: "D1", kind: .handoff, state: ChatDeskItemState(rawValue: snapshot.deskState) ?? .open, revision: snapshot.deskRevision,
            createdAt: 1_700_000_000, expiresAt: 1_700_086_400, requester: ChatDeskPersonWire(id: "U1", name: "Minh Pham"),
            place: ChatDeskPlaceWire(conversationId: "C9", label: "#announcements"),
            text: "Post the 4.2 release notes draft in #announcements", why: "Minh asked in a direct message"
        )
    }
}
