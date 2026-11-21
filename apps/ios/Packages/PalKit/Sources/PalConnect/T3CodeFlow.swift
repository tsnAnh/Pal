import Foundation
import PalProtocol
import PalTransport

public enum T3CodeFlow {
    public static let flowID = "t3code"

    public enum Resume: Sendable, Equatable {
        case address
        case signIn

        var stepID: String {
            switch self {
            case .address: "address"
            case .signIn: "signin"
            }
        }
    }

    public static func steps() -> [FlowStep] {
        [
            FlowStep(
                id: "network", title: String(localized: "Turn on network access in T3 Code"),
                body: String(localized: "On your Mac, open T3 Code, go to Settings and turn on Network access. Or run the command below in a terminal."),
                kind: .copyCard(copies: [
                    SetupCopy(label: String(localized: "Where"), value: String(localized: "T3 Code, Settings, Network access")),
                    SetupCopy(label: String(localized: "Command"), value: "t3 serve --host <your Mac's Tailscale address>"),
                ])
            ),
            FlowStep(
                id: "address", title: String(localized: "Paste the address and port"),
                body: String(localized: "Use your Mac's Tailscale address and the port T3 Code shows, for example 100.64.0.5:3773."),
                kind: .paste(fields: [SetupField(id: "address", label: String(localized: "Address"), secret: false)]),
                primaryTitle: String(localized: "Check address")
            ),
            FlowStep(
                id: "signin", title: String(localized: "Sign in to T3 Code"),
                body: String(localized: "A browser window opens. Sign in to T3 Code, then allow access. You come straight back here."),
                kind: .browserRoundTrip(
                    waitingTitle: String(localized: "Waiting for T3 Code"),
                    waitingBody: String(localized: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done.")
                ),
                primaryTitle: String(localized: "Sign in with T3 Code")
            ),
            FlowStep(
                id: "done", title: String(localized: "Connected"),
                kind: .success(
                    title: String(localized: "T3 Code is connected"),
                    body: String(localized: "Your bots can send coding work to T3 Code while it is reachable. You will not be asked for this again.")
                )
            ),
        ]
    }

    public static func engine(resumeAt resume: Resume?) -> StepFlowEngine? {
        StepFlowEngine(flowID: flowID, steps: steps(), resume: resume.map { StepFlowProgress(flowID: flowID, stepID: $0.stepID) })
    }

    public static func runner(service: ConnectAppsService) -> StepFlowModel.Runner {
        { step, values in
            if step.id == "address" { try await service.checkT3Address(values["address"] ?? "") }
            if step.id == "signin" { try await service.signInT3Code() }
        }
    }

    public static func classify(_ error: any Error) -> SetupStatus {
        let subject = T3CodeConnector.name
        switch error {
        case let failure as T3CodeFailure:
            return failure.status
        case let address as T3AddressError:
            var status = SetupStatus(code: SetupStatusClass.vendorRefusedValue.rawValue, subject: subject, valueName: "address")
            status.title = String(localized: "That address does not look right")
            status.reason = address.message
            status.code = "invalid_address"
            return status
        case let failure as ConnectAppsError:
            return fromConnect(failure, subject: subject)
        case let transport as GatewayTransportError:
            return fromTransport(transport, subject: subject)
        case let failure as ConnectorFailure:
            return fromConnector(failure, subject: subject)
        default:
            return SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: subject)
        }
    }

    private static func fromConnect(_ error: ConnectAppsError, subject: String) -> SetupStatus {
        switch error {
        case .faulted(let fault):
            return SetupStatus(fault: fault, subject: subject)
        case .oauthClient(_, let fault?):
            return SetupStatus(fault: fault, subject: subject)
        case .failed:
            return SetupStatus(code: SetupStatusClass.offline.rawValue, subject: subject)
        case .unavailable, .cancelled, .credentialsRequired, .signInFailed, .signInRefused, .adminApprovalPending, .oauthClient, .accountName:
            return SetupStatus(code: SetupStatusClass.internalFault.rawValue, subject: subject)
        }
    }

    private static func fromTransport(_ error: GatewayTransportError, subject: String) -> SetupStatus {
        if case .rpc(let rpc) = error {
            return SetupStatus(fault: GatewayFault(rpc, method: "mcp.servers"), subject: subject)
        }
        return SetupStatus(code: SetupStatusClass.offline.rawValue, subject: subject)
    }

    private static func fromConnector(_ error: ConnectorFailure, subject: String) -> SetupStatus {
        let code: SetupStatusClass = switch error {
        case .offline: .offline
        case .unreachable: .serverUnreachable
        case .authRefused: .needsReauth
        default: .internalFault
        }
        return SetupStatus(code: code.rawValue, subject: subject)
    }
}
