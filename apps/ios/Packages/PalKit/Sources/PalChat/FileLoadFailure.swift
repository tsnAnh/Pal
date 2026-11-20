import Foundation
import PalProtocol
import PalTransport

public struct FileLoadFailure: Error, Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        case notFound
        case notAllowed
        case tooLarge(limitMegabytes: Int)
        case unreachable
        case internalFailure
        case unknown(code: Int?)
    }

    public static let downloadLimitBytes = 16_000_000

    public let cause: Cause

    public init(cause: Cause) {
        self.cause = cause
    }

    public init(describing error: Error, limitBytes: Int = FileLoadFailure.downloadLimitBytes) {
        switch error {
        case let failure as FileLoadFailure:
            self = failure
        case let rpc as RPCError:
            self.init(cause: Self.cause(forRPC: rpc, limitBytes: limitBytes))
        case GatewayTransportError.rpc(let rpc):
            self.init(cause: Self.cause(forRPC: rpc, limitBytes: limitBytes))
        case ChatError.notConnected, is URLError:
            self.init(cause: .unreachable)
        case GatewayTransportError.encoding:
            self.init(cause: .unknown(code: nil))
        case is GatewayTransportError:
            self.init(cause: .unreachable)
        default:
            self.init(cause: .unknown(code: nil))
        }
    }

    public var reason: String {
        switch cause {
        case .notFound: "Not found on the bot's computer"
        case .notAllowed: "Not allowed to share this file"
        case .tooLarge(let limit): "Too large to download (limit \(limit) MB)"
        case .unreachable: "Can't reach the bot right now"
        case .internalFailure: "The bot couldn't load this file right now"
        case .unknown: "The bot could not provide it right now."
        }
    }

    public var code: Int? {
        switch cause {
        case .unknown(let code): code
        default: nil
        }
    }

    public var message: String {
        guard let code else { return reason }
        return "\(reason) · Error \(code)"
    }

    public var isTransient: Bool {
        switch cause {
        case .unreachable, .internalFailure, .unknown: true
        case .notFound, .notAllowed, .tooLarge: false
        }
    }

    private static func cause(forRPC rpc: RPCError, limitBytes: Int) -> Cause {
        switch rpc.code {
        case 4151: .notFound
        case 4152: .tooLarge(limitMegabytes: max(1, limitBytes / 1_000_000))
        case 4154: .notAllowed
        case 5151: .internalFailure
        default: .unknown(code: rpc.code)
        }
    }
}

public enum FileCardPhase: Sendable, Equatable {
    case checking
    case ready
    case failed(FileLoadFailure)

    public var offersRetry: Bool {
        guard case .failed(let failure) = self else { return false }
        return failure.isTransient
    }
}
