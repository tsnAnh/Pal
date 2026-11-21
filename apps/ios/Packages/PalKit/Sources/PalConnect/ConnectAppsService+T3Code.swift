import Foundation
import PalProtocol
import PalTransport

public struct T3CodeFailure: Error, Sendable, Equatable {
    public var status: SetupStatus
}

extension ConnectAppsService {
    public func checkT3Address(_ input: String) async throws {
        let url = try T3CodeConnector.mcpURL(fromInput: input)
        let created = try await saveT3Server(url: url)
        do {
            let result = try await call("mcp.servers.test", ["name": .string(T3CodeConnector.slug)])
            if let status = Self.t3Failure(testResult: result) { throw T3CodeFailure(status: status) }
        } catch {
            if created { await removeQuietly(T3CodeConnector.slug) }
            throw error
        }
    }

    public func signInT3Code() async throws {
        do {
            try await authorizeMcp(name: T3CodeConnector.slug, browser: systemBrowser)
        } catch let error as ConnectAppsError {
            throw Self.t3SignInFailure(error)
        }
    }

    public func probeT3Code() async -> T3Reach {
        guard let result = try? await call("mcp.servers.test", ["name": .string(T3CodeConnector.slug)]) else { return .unreachable }
        return Self.t3Reach(testResult: result)
    }

    private func saveT3Server(url: String) async throws -> Bool {
        let name = JSONValue.string(T3CodeConnector.slug)
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

    static func t3Failure(testResult result: JSONValue) -> SetupStatus? {
        if result["ok"]?.boolValue == true || result["oauth_needed"]?.boolValue == true { return nil }
        let reason = result["reason"]?.stringValue?.lowercased() ?? ""
        let code = switch reason {
        case "unreachable": SetupStatusClass.serverUnreachable.rawValue
        case "not_mcp": SetupStatusClass.notMcpServer.rawValue
        default: SetupStatusClass.internalFault.rawValue
        }
        return SetupStatus(code: code, method: "mcp.servers.test", subject: T3CodeConnector.name)
    }

    static func t3Reach(testResult result: JSONValue) -> T3Reach {
        if result["ok"]?.boolValue == true { return .reachable }
        let refused = result["reason"]?.stringValue?.lowercased() == "auth_refused"
        let oauthNeeded = result["oauth_needed"]?.boolValue == true
        return (refused || oauthNeeded) ? .needsSignIn : .unreachable
    }

    private static func t3SignInFailure(_ error: ConnectAppsError) -> any Error {
        let method = "mcp.servers.oauth"
        switch error {
        case .cancelled:
            return CancellationError()
        case .faulted, .failed:
            return error
        case .signInFailed(let reason):
            if reason == McpSignInFailure.redirectRefused.reason {
                return T3CodeFailure(status: SetupStatus(code: "invalid_redirect_uri", method: method, subject: T3CodeConnector.name))
            }
            var status = SetupStatus(code: SetupStatusClass.needsReauth.rawValue, method: method, subject: T3CodeConnector.name)
            status.title = String(localized: "Sign-in did not finish")
            status.reason = reason
            return T3CodeFailure(status: status)
        case .unavailable, .credentialsRequired, .oauthClient, .signInRefused, .adminApprovalPending, .accountName:
            return T3CodeFailure(status: SetupStatus(code: SetupStatusClass.internalFault.rawValue, method: method, subject: T3CodeConnector.name))
        }
    }
}
