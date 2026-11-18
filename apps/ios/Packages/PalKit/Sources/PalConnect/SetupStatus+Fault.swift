import Foundation
import PalProtocol

extension SetupStatus {
    public init(
        fault: GatewayFault, subject: String? = nil, valueName: String = "token", device: String = "device"
    ) {
        self.init(
            code: fault.reason, method: fault.method, trace: fault.trace.rawValue, gatewayVersion: fault.gatewayVersion,
            subject: subject, valueName: valueName, device: device
        )
    }
}
