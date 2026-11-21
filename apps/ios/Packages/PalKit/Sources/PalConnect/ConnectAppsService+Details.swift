import Foundation
import PalProtocol
import PalTransport

extension ConnectAppsService {
    public func details(slug: String) async throws -> ConnectorDetails? {
        let reply: JSONValue
        do {
            reply = try await rawCall("connectors.details", ["slug": .string(slug)])
        } catch let error as GatewayTransportError {
            if case .rpc(let rpc) = error, rpc.code == -32601 { return nil }
            throw Self.map(error, method: "connectors.details")
        }
        do { return try reply.decoded(as: ConnectorDetails.self) } catch { throw ConnectAppsError.failed }
    }

    public func setPolicy(slug: String, group: ConnectorToolGroup, mode: ConnectorPolicyMode) async throws -> ConnectorPolicy {
        guard group.modes.contains(mode) else { throw ConnectAppsError.failed }
        let reply = try await call(
            "connectors.details.policy.set", ["slug": .string(slug), "group": .string(group.rawValue), "mode": .string(mode.rawValue)]
        )
        guard let policy = reply["policy"], let stored = try? policy.decoded(as: ConnectorPolicy.self) else { throw ConnectAppsError.failed }
        return stored
    }
}
