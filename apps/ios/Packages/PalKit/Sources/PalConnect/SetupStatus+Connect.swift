import Foundation
import PalProtocol

extension SetupStatus {
    public init(error: any Error, subject: String?, valueName: String = "token", device: String = "device") {
        self = Self.status(for: error, subject: subject, valueName: valueName, device: device)
    }

    public static func checkFailed(_ failure: SetupCheckFailure, subject: String, valueName: String) -> SetupStatus {
        let method = "connectors.setup.check"
        switch failure.code {
        case "INVALID_TOKEN", "INVALID_CLIENT":
            return SetupStatus(code: failure.code, method: method, subject: subject, valueName: valueName)
        case "CHECK_UNAVAILABLE":
            var status = SetupStatus(code: failure.code, method: method, subject: subject, valueName: valueName)
            status.title = String(localized: "Pal could not check with \(subject)")
            status.reason = String(localized: "Try again in a moment.")
            status.actionTitle = String(localized: "Try again")
            return status
        default:
            var status = SetupStatus(code: failure.code, method: method, subject: subject, valueName: valueName)
            status.reason = failure.reason
            return status
        }
    }

    public static func addressCheck(_ check: PublicAddressCheck) -> SetupStatus? {
        let reason: String
        switch check.outcome {
        case .reachable: return nil
        case .notReachable: reason = String(localized: "Check that your Pal is online and that this address points to it.")
        case .wrongService: reason = String(localized: "Something else answered at this address.")
        case .notServed: reason = String(localized: "Your Pal is not serving web sign-in on this address yet.")
        case .noAddress: reason = String(localized: "Pal has no web address saved yet.")
        }
        var status = SetupStatus(code: check.outcome.rawValue.uppercased(), method: "webapp.public_url.check")
        status.title = String(localized: "Pal could not reach this address")
        status.reason = reason
        status.actionTitle = String(localized: "Check again")
        return status
    }

    public static func pasteRefused(note: String) -> SetupStatus {
        var status = SetupStatus(code: SetupStatusClass.vendorRefusedValue.rawValue)
        status.title = String(localized: "That address did not work")
        status.reason = note
        status.actionTitle = String(localized: "Edit address")
        return status
    }

    private static func status(for error: any Error, subject: String?, valueName: String, device: String) -> SetupStatus {
        switch error {
        case let error as ConnectAppsError:
            return connectStatus(error, subject: subject, valueName: valueName, device: device)
        case let error as PublicAddressError:
            return addressStatus(error, subject: subject, valueName: valueName, device: device)
        case let fault as GatewayFault:
            return SetupStatus(fault: fault, subject: subject, valueName: valueName, device: device)
        default:
            return SetupStatus(code: "offline", subject: subject, valueName: valueName, device: device)
        }
    }

    private static func coded(
        _ code: String, fault: GatewayFault?, subject: String?, valueName: String, device: String
    ) -> SetupStatus {
        SetupStatus(
            code: code, method: fault?.method, trace: fault?.trace.rawValue, gatewayVersion: fault?.gatewayVersion,
            subject: subject, valueName: valueName, device: device
        )
    }

    private static func connectStatus(_ error: ConnectAppsError, subject: String?, valueName: String, device: String) -> SetupStatus {
        switch error {
        case .oauthClient(let failure, let fault):
            var status = coded(oauthClientCode(failure), fault: fault, subject: subject, valueName: valueName, device: device)
            if status.kind == .internalFault { status.reason = failure.reason }
            return status
        case .faulted(let fault):
            return SetupStatus(fault: fault, subject: subject, valueName: valueName, device: device)
        case .signInFailed(let reason):
            var status = SetupStatus(code: "sign_in_failed", subject: subject, valueName: valueName, device: device)
            status.title = String(localized: "Sign-in did not finish")
            status.reason = reason
            status.actionTitle = String(localized: "Try again")
            return status
        case .unavailable:
            return SetupStatus(code: "unavailable", subject: subject, valueName: valueName, device: device)
        case .cancelled:
            return SetupStatus(code: "cancelled", subject: subject, valueName: valueName, device: device)
        case .credentialsRequired:
            return SetupStatus(code: "credentials_required", subject: subject, valueName: valueName, device: device)
        case .failed:
            return SetupStatus(code: "failed", subject: subject, valueName: valueName, device: device)
        }
    }

    private static func oauthClientCode(_ failure: OAuthClientFailure) -> String {
        switch failure {
        case .invalidClient: "invalid_client"
        case .notOwner: "not_owner"
        case .unreachable: "unreachable"
        case .needsSetup, .needsPublicURL, .clientUnreadable, .saveFailed, .connectFailed: failure.rawValue
        }
    }

    private static func addressStatus(_ error: PublicAddressError, subject: String?, valueName: String, device: String) -> SetupStatus {
        switch error.reason {
        case .refused(let problem):
            var status = coded(
                SetupStatusClass.vendorRefusedValue.rawValue, fault: error.fault, subject: subject, valueName: valueName, device: device
            )
            status.title = String(localized: "That address was not accepted")
            status.reason = problem.message
            status.actionTitle = String(localized: "Edit address")
            return status
        case .ownerOnly:
            return coded(SetupStatusClass.forbidden.rawValue, fault: error.fault, subject: subject, valueName: valueName, device: device)
        case .managed:
            var status = coded("managed", fault: error.fault, subject: subject, valueName: valueName, device: device)
            status.reason = String(localized: "This address is managed for you and cannot be changed here.")
            return status
        case .other:
            guard let fault = error.fault else {
                return SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: subject, valueName: valueName, device: device)
            }
            return SetupStatus(fault: fault, subject: subject, valueName: valueName, device: device)
        }
    }
}
