import Foundation
import PalBotProfile
import PalProtocol

actor ScriptedChatInstallGateway: ChatInstallClient {
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
    }

    private var snapshot: Snapshot
    private var listeners: [AsyncStream<ChatInstallChangedPayload>.Continuation] = []

    private init() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains(Self.resetArgument) { defaults.removeObject(forKey: Self.defaultsKey) }
        snapshot = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    nonisolated var source: ChatInstallSource {
        ChatInstallSource(client: self) {
            AsyncStream { continuation in Task { await self.listen(continuation) } }
        }
    }

    private func listen(_ continuation: AsyncStream<ChatInstallChangedPayload>.Continuation) {
        listeners.append(continuation)
    }

    private func move(_ step: String, done: String? = nil) {
        snapshot.step = step
        snapshot.revision += 1
        if let done { snapshot.done.append(done) }
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.defaultsKey)
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
        case "needs_manual_step":
            ["kind": "button", "action_id": "app_level_credential", "link": "https://api.slack.com/apps/A1/general", "copy_text": NSNull()]
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
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static let refusal = GatewayFault(code: 4403, reason: "owner_only", trace: TraceID("7f3k2m9a")!, method: "chat.provider.list",
                                      source: .gateway, gatewayVersion: "291aaa2b")

    func providers() async throws -> [ChatCapabilitiesWire] {
        if ProcessInfo.processInfo.arguments.contains(Self.failArgument) { throw ChatInstallClientError.faulted(.forbidden, Self.refusal) }
        return [try decode(ChatCapabilitiesWire.self, [
            "provider_id": "slack", "requires_config_credential": true, "creates_app": true,
            "capabilities": [
                ["capability": "set_icon", "mode": "guided"], ["capability": "app_level_credential", "mode": "guided"],
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
            let remaining = ["set_icon", "app_level_credential"].filter { !snapshot.done.contains($0) && $0 != step }
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

    func storeSecret(label: String, value: String) async throws -> String {
        "vault-scripted-\(snapshot.revision)"
    }
}
