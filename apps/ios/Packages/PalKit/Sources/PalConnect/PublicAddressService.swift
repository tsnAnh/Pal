import Foundation
import PalProtocol
import PalTransport

public struct PublicAddressState: Sendable, Equatable {
    public var url: String?
    public var routesEnabled: Bool
    public var suggestion: String?

    public init(url: String? = nil, routesEnabled: Bool = false, suggestion: String? = nil) {
        self.url = url
        self.routesEnabled = routesEnabled
        self.suggestion = suggestion
    }

    init(_ value: JSONValue) throws {
        guard let routes = value["routes_enabled"]?.boolValue else { throw ConnectAppsError.failed }
        self.init(url: Self.text(value["url"]), routesEnabled: routes, suggestion: Self.text(value["suggestion"]))
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}

public enum PublicAddressOutcome: String, Sendable, Equatable, CaseIterable {
    case reachable
    case notReachable = "not_reachable"
    case wrongService = "wrong_service"
    case notServed = "not_served"
    case noAddress = "no_address"
}

public struct PublicAddressCheck: Sendable, Equatable {
    public var outcome: PublicAddressOutcome
    public var url: String?

    public init(outcome: PublicAddressOutcome, url: String? = nil) {
        self.outcome = outcome
        self.url = url
    }
}

public struct PublicAddressError: Error, Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case refused(PublicAddress.Problem)
        case ownerOnly
        case managed
        case other
    }

    public var reason: Reason
    public var fault: GatewayFault?

    public init(_ reason: Reason, fault: GatewayFault? = nil) {
        self.reason = reason
        self.fault = fault
    }

    static let invalidParamsCode = 4000
    static let managedCode = 4030
    static let ownerOnlyCode = 4403

    init(_ rpc: RPCError, method: String) {
        let reason: Reason = switch rpc.code {
        case Self.ownerOnlyCode: .ownerOnly
        case Self.managedCode: .managed
        case Self.invalidParamsCode: rpc.data?["problem"]?.stringValue.flatMap(PublicAddress.Problem.init(rawValue:)).map(Reason.refused) ?? .other
        default: .other
        }
        self.init(reason, fault: GatewayFault(rpc, method: method))
    }
}

extension ConnectAppsService {
    public func publicAddress() async throws -> PublicAddressState {
        try PublicAddressState(try await publicAddressCall("webapp.public_url.get", [:]))
    }

    public func savePublicAddress(_ url: String) async throws -> PublicAddressState {
        try PublicAddressState(try await publicAddressCall("webapp.public_url.set", ["url": .string(url)]))
    }

    public func checkPublicAddress() async throws -> PublicAddressCheck {
        let reply = try await publicAddressCall("webapp.public_url.check", [:])
        guard let outcome = reply["outcome"]?.stringValue.flatMap(PublicAddressOutcome.init(rawValue:)) else { throw ConnectAppsError.failed }
        return PublicAddressCheck(outcome: outcome, url: reply["url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func publicAddressCall(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error else { throw PublicAddressError(.other, fault: .transport("unreachable", method: method)) }
            throw PublicAddressError(rpc, method: method)
        }
    }
}
