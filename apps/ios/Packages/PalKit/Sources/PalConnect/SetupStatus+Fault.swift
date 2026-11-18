import Foundation
import PalProtocol
import PalTransport

public struct SetupStatusError: Error, Sendable, Equatable {
    public let status: SetupStatus

    public init(_ status: SetupStatus) {
        self.status = status
    }
}

extension SetupStatus {
    public init(error: any Error, method: String? = nil, subject: String? = nil, valueName: String = "token", device: String = "device") {
        self = Self.status(for: error, method: method, subject: subject, valueName: valueName, device: device)
    }

    private static func status(for error: any Error, method: String?, subject: String?, valueName: String, device: String) -> SetupStatus {
        let code: String
        switch error {
        case let carried as SetupStatusError:
            return carried.status
        case let known as ConnectAppsError:
            if let fault = known.fault { return SetupStatus(fault: fault, subject: subject, valueName: valueName, device: device) }
            code = known.oauthClientFailure?.rawValue ?? SetupStatusClass.internalFault.rawValue
        case GatewayTransportError.rpc(let rpc):
            return SetupStatus(fault: GatewayFault(rpc, method: method ?? "gateway"), subject: subject, valueName: valueName, device: device)
        case is GatewayTransportError:
            code = SetupStatusClass.offline.rawValue
        default:
            code = SetupStatusClass.internalFault.rawValue
        }
        return SetupStatus(code: code, method: method, subject: subject, valueName: valueName, device: device)
    }

    public init(
        fault: GatewayFault, subject: String? = nil, valueName: String = "token", device: String = "device"
    ) {
        self.init(
            code: fault.reason, method: fault.method, trace: fault.trace.rawValue, gatewayVersion: fault.gatewayVersion,
            subject: subject, valueName: valueName, device: device
        )
    }
}
