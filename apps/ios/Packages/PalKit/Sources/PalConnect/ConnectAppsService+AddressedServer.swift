import Foundation
import PalProtocol
import PalTransport

extension ConnectAppsService {
    func saveAddressedServer(name slug: String, url: String) async throws -> Bool {
        let name = JSONValue.string(slug)
        let config: JSONValue = ["url": .string(url), "transport": "http"]
        do {
            _ = try await rawCall("mcp.servers.add", ["name": name, "config": config])
            return true
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error, rpc.code == 4090 else { throw Self.map(error, method: "mcp.servers.add") }
        }
        _ = try await call("mcp.servers.update", ["name": name, "config": config])
        return false
    }

    static func addressedFailure(testResult result: JSONValue, subject: String) -> SetupStatus? {
        if result["ok"]?.boolValue == true || result["oauth_needed"]?.boolValue == true { return nil }
        let reason = result["reason"]?.stringValue?.lowercased() ?? ""
        let code = switch reason {
        case "unreachable": SetupStatusClass.serverUnreachable.rawValue
        case "not_mcp": SetupStatusClass.notMcpServer.rawValue
        default: SetupStatusClass.internalFault.rawValue
        }
        return SetupStatus(code: code, method: "mcp.servers.test", subject: subject)
    }
}

enum AddressedFlowStatus {
    static func fromConnect(_ error: ConnectAppsError, subject: String) -> SetupStatus {
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

    static func fromTransport(_ error: GatewayTransportError, subject: String) -> SetupStatus {
        if case .rpc(let rpc) = error {
            return SetupStatus(fault: GatewayFault(rpc, method: "mcp.servers"), subject: subject)
        }
        return SetupStatus(code: SetupStatusClass.offline.rawValue, subject: subject)
    }

    static func fromConnector(_ error: ConnectorFailure, subject: String) -> SetupStatus {
        let code: SetupStatusClass = switch error {
        case .offline: .offline
        case .unreachable: .serverUnreachable
        case .authRefused: .needsReauth
        default: .internalFault
        }
        return SetupStatus(code: code.rawValue, subject: subject)
    }
}
