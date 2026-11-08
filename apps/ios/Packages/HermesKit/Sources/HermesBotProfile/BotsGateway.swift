import Foundation
import HermesProtocol
import HermesTransport

public struct BotsGateway: Sendable {
    public typealias Call = @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue

    private let perform: Call

    public init(call: @escaping Call) {
        perform = call
    }

    public func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await perform(method, .object(params))
    }

    func scoped(_ method: String, profile: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var merged = params
        merged["profile"] = .string(profile)
        return try await call(method, merged)
    }

    func decoded<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        do {
            return try value.decoded(as: type)
        } catch {
            throw BotsError.invalidResponse
        }
    }
}

public enum BotsError: Error, Sendable, Equatable {
    case permissionDenied
    case notFound
    case conflict
    case rejected(reason: String?)
    case unavailable
    case invalidResponse

    public static func surface(_ error: any Error) -> any Error {
        error is CancellationError ? error : classify(error)
    }

    public static func classify(_ error: any Error) -> BotsError {
        if let bots = error as? BotsError { return bots }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unavailable }
        switch rpc.reasonCode ?? rpc.message {
        case "permission_denied", "profile_mismatch": return .permissionDenied
        case "not_found": return .notFound
        default: return .rejected(reason: rpc.reasonCode)
        }
    }
}
