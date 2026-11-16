import Foundation
import PalProtocol
import PalTransport

public struct ImageLoadFailure: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public init(describing error: Error) {
        switch error {
        case let failure as ImageLoadFailure:
            self = failure
        case let rpc as RPCError:
            self.init(reason: Self.reason(forRPC: rpc))
        case GatewayTransportError.rpc(let rpc):
            self.init(reason: Self.reason(forRPC: rpc))
        case ChatError.notConnected:
            self.init(reason: "You are not connected right now.")
        case let url as URLError:
            self.init(reason: url.code == .notConnectedToInternet ? "You are offline." : "The image could not be downloaded.")
        default:
            self.init(reason: "The image could not be read.")
        }
    }

    public static func rpcCode(of error: Error) -> Int? {
        switch error {
        case let rpc as RPCError: rpc.code
        case GatewayTransportError.rpc(let rpc): rpc.code
        default: nil
        }
    }

    public var message: String { "Image could not be loaded: \(reason)" }

    private static func reason(forRPC rpc: RPCError) -> String {
        switch rpc.code {
        case 4151: "It is no longer available."
        case 4152: "It is too large to download."
        default: "The bot could not provide it right now."
        }
    }
}
