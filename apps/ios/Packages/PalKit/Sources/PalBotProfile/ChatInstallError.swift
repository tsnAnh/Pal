import Foundation
import PalProtocol
import PalTransport

public enum ChatFailureReason: String, Sendable, Equatable, CaseIterable {
    case offline
    case timedOut = "timed_out"
    case forbidden
    case invalidParams = "invalid_params"
    case decode
    case gateway
}

public enum ChatInstallClientError: Error, Sendable, Equatable {
    case unsupported
    case staleRevision
    case offline
    case timedOut
    case failed(ChatFailureReason)
    case faulted(ChatFailureReason, GatewayFault)

    public var isUnreachable: Bool { reason == .offline || reason == .timedOut }

    public var reason: ChatFailureReason {
        switch self {
        case .offline: .offline
        case .timedOut: .timedOut
        case .failed(let reason), .faulted(let reason, _): reason
        case .unsupported, .staleRevision: .gateway
        }
    }

    public var fault: GatewayFault? {
        if case .faulted(_, let fault) = self { return fault }
        return nil
    }

    public init(_ error: any Error) {
        if let known = error as? ChatInstallClientError {
            self = known
        } else if let transport = error as? GatewayTransportError {
            switch transport {
            case .timedOut: self = .timedOut
            case .closed: self = .offline
            case .rpc(let rpc): self = Self(rpc)
            default: self = .failed(.gateway)
            }
        } else {
            self = .failed(.gateway)
        }
    }

    public init(_ error: any Error, method: String) {
        let plain = Self(error)
        switch (error as? GatewayTransportError, plain) {
        case (.rpc(let rpc)?, .failed(let reason)):
            self = .faulted(reason, GatewayFault(rpc, method: method))
        case (_?, .offline), (_?, .timedOut):
            self = .faulted(plain.reason, .transport(plain.reason == .timedOut ? "timeout" : "offline", method: method))
        default:
            self = plain
        }
    }

    public static func decode(method: String) -> ChatInstallClientError {
        .faulted(.decode, .decode(method: method))
    }

    public init(_ rpc: RPCError) {
        let reason = rpc.reasonCode
        if rpc.code == -32601 || reason == ChatRpcErrorReason.notImplemented.rawValue {
            self = .unsupported
        } else if reason == ChatRpcErrorReason.staleRevision.rawValue {
            self = .staleRevision
        } else if rpc.code == 4403 || reason == "owner_only" || reason == "permission_denied" {
            self = .failed(.forbidden)
        } else if rpc.code == 4001 || rpc.code == -32602 {
            self = .failed(.invalidParams)
        } else {
            self = .failed(.gateway)
        }
    }
}
