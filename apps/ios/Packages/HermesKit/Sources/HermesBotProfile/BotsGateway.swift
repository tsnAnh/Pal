import Foundation
import HermesProtocol
import HermesRoster
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

    var roster: RosterGateway {
        RosterGateway(call: perform)
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
        if let admin = error as? BotAdminError { return BotsError(admin) }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unavailable }
        switch rpc.reasonCode ?? rpc.message {
        case "permission_denied", "profile_mismatch": return .permissionDenied
        case "not_found": return .notFound
        default: return .rejected(reason: rpc.reasonCode)
        }
    }
}

extension BotsError {
    init(_ admin: BotAdminError) {
        switch admin {
        case .permissionDenied: self = .permissionDenied
        case .botNotFound: self = .notFound
        case .conflict: self = .conflict
        case .rejected: self = .rejected(reason: nil)
        case .invalidName: self = .rejected(reason: "invalid_name")
        case .nameTaken: self = .rejected(reason: "name_taken")
        case .unavailable, .incomplete: self = .unavailable
        }
    }
}
