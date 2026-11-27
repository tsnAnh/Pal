import Foundation
import PalProtocol
import PalTransport

struct TimeLimitedChatInstallClient: ChatInstallClient {
    let base: any ChatInstallClient
    let limit: Duration

    private func bounded<Value: Sendable>(
        _ call: @escaping @Sendable (any ChatInstallClient) async throws -> Value
    ) async throws -> Value {
        let base = base
        do {
            return try await Deadline.run(limit) { try await call(base) }
        } catch is DeadlineExceeded {
            throw ChatInstallClientError.timedOut
        }
    }

    func providers() async throws -> [ChatCapabilitiesWire] { try await bounded { try await $0.providers() } }

    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult { try await bounded { try await $0.status(scope) } }

    func begin(_ scope: ChatInstallScope) async throws { try await bounded { try await $0.begin(scope) } }

    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws {
        try await bounded { try await $0.advance(scope, advance) }
    }

    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire] { try await bounded { try await $0.spaces(scope) } }

    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult {
        try await bounded { try await $0.join(scope, spaceId: spaceId) }
    }

    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire] { try await bounded { try await $0.bindings(scope) } }

    func revoke(_ scope: ChatInstallScope) async throws { try await bounded { try await $0.revoke(scope) } }

    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult {
        try await bounded { try await $0.updateIdentity(scope) }
    }

    func setIcon(_ scope: ChatInstallScope, png: Data) async throws { try await bounded { try await $0.setIcon(scope, png: png) } }

    func storeSecret(label: String, value: String) async throws -> String {
        try await bounded { try await $0.storeSecret(label: label, value: value) }
    }
}
