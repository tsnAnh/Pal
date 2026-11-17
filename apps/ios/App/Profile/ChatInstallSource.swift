import Foundation
import PalBotProfile
import PalClient
import PalProtocol
import PalSettings
import PalTransport

struct ChatInstallSource: Sendable {
    let client: any ChatInstallClient
    let events: @Sendable () -> AsyncStream<ChatInstallChangedPayload>

    static let scriptedArgument = "-hermes-test-chat-install"

    @MainActor
    static func make(botName: String, connection: ConnectionModel) -> ChatInstallSource {
        if ProcessInfo.processInfo.arguments.contains(scriptedArgument) {
            return ScriptedChatInstallGateway.shared.source
        }
        let call: @Sendable (String, JSONValue?) async throws -> JSONValue = { method, params in try await connection.rpc(method, params) }
        let client = GatewayChatInstallClient(bot: botName, call: call, vault: SettingsAPI(profile: botName, call: call))
        let connect = connection.client
        return ChatInstallSource(client: client) {
            AsyncStream { continuation in
                let task = Task {
                    while !Task.isCancelled {
                        if let connect, let gateway = try? await connect.connect(profile: botName) {
                            for await event in gateway.events where event.type == "chat.install.changed" {
                                if let payload = try? event.payload?.decoded(as: ChatInstallChangedPayload.self) {
                                    continuation.yield(payload)
                                }
                            }
                            await gateway.close()
                        }
                        try? await Task.sleep(for: .seconds(3))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

struct GatewayChatInstallClient: ChatInstallClient {
    let bot: String
    let call: @Sendable (String, JSONValue?) async throws -> JSONValue
    let vault: SettingsAPI

    private func perform(_ method: String, _ scope: ChatInstallScope?, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params = extra
        params["profile"] = .string(bot)
        if let scope {
            params["provider_id"] = .string(scope.provider)
            params["workspace"] = .string(scope.workspace)
        }
        do {
            return try await call(method, .object(params))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatInstallClientError(error, method: method)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue, _ method: String) throws -> T {
        do { return try value.decoded(as: type) } catch { throw ChatInstallClientError.decode(method: method) }
    }

    func providers() async throws -> [ChatCapabilitiesWire] {
        try decode(ChatProviderListResult.self, await perform("chat.provider.list", nil), "chat.provider.list").providers
    }

    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult {
        try decode(ChatInstallStatusResult.self, await perform("chat.install.status", scope), "chat.install.status")
    }

    func begin(_ scope: ChatInstallScope) async throws {
        _ = try await perform("chat.install.begin", scope)
    }

    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws {
        var extra: [String: JSONValue] = [
            "event": .string(advance.event.rawValue), "expected_revision": .int(advance.expectedRevision),
        ]
        if let step = advance.manualStep { extra["manual_step"] = .string(step.rawValue) }
        if let id = advance.vaultItemId { extra["vault_item_id"] = .string(id) }
        if let id = advance.refreshVaultItemId { extra["refresh_vault_item_id"] = .string(id) }
        if let member = advance.ownerMemberId { extra["owner_member_id"] = .string(member) }
        _ = try await perform("chat.install.advance", scope, extra)
    }

    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire] {
        try decode(ChatSpacesListResult.self, await perform("chat.spaces.list", scope), "chat.spaces.list").spaces
    }

    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult {
        try decode(ChatSpaceJoinResult.self, await perform("chat.space.join", scope, ["space_id": .string(spaceId)]), "chat.space.join")
    }

    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire] {
        try decode(ChatBindingListResult.self, await perform("chat.binding.list", scope), "chat.binding.list").bindings
    }

    func revoke(_ scope: ChatInstallScope) async throws {
        _ = try await perform("chat.install.revoke", scope)
    }

    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult {
        try decode(ChatIdentityUpdateResult.self, await perform("chat.install.update_identity", scope), "chat.install.update_identity")
    }

    func storeSecret(label: String, value: String) async throws -> String {
        do {
            return try await vault.addVaultAPIKey(VaultAPIKeyDraft(label: label, apiKey: value))
        } catch SettingsFailure.offline {
            throw ChatInstallClientError.offline
        } catch {
            throw ChatInstallClientError.failed(.gateway)
        }
    }
}
