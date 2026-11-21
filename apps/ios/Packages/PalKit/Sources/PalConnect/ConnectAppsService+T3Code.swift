import Foundation
import PalProtocol
import PalTransport

public struct T3CodeFailure: Error, Sendable, Equatable {
    public var status: SetupStatus
}

extension ConnectAppsService {
    public func checkT3Address(_ input: String) async throws {
        let url = try T3CodeConnector.mcpURL(fromInput: input)
        let created = try await saveAddressedServer(name: T3CodeConnector.slug, url: url)
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

    static func t3Failure(testResult result: JSONValue) -> SetupStatus? {
        addressedFailure(testResult: result, subject: T3CodeConnector.name)
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
