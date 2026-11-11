import Foundation
import PalProtocol
import PalTransport

public struct RosterGateway: Sendable {
    public typealias Call = @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue

    private let perform: Call

    public init(call: @escaping Call) {
        perform = call
    }

    public init(connection: GatewayConnection) {
        perform = { method, params in try await connection.call(method, params: params) }
    }

    public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        try await perform(method, params)
    }
}

public enum BotAdminError: Error, Sendable, Equatable {
    case permissionDenied
    case botNotFound
    case invalidName
    case nameTaken
    case conflict
    case rejected
    case unavailable
    case incomplete(profile: String)

    static let createRefusedCode = 4062

    public static func classify(_ error: any Error) -> BotAdminError {
        if let admin = error as? BotAdminError { return admin }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unavailable }
        switch rpc.reasonCode ?? rpc.message {
        case "permission_denied", "profile_mismatch": return .permissionDenied
        case "not_found": return .botNotFound
        default: break
        }
        if rpc.code == createRefusedCode {
            return rpc.message.localizedCaseInsensitiveContains("already exists") ? .nameTaken : .invalidName
        }
        return .rejected
    }
}
