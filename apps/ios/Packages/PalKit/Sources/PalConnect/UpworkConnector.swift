import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalTransport

public enum UpworkConnector {
    public static let presetName = "upwork"
    public static let service = "mcp:upwork"
    public static let serverURL = URL(string: "https://mcp.upwork.com/mcp")!
}

extension ConnectApp {
    public var requiresMacSignIn: Bool {
        if case .mcp(let name, _) = source { return name == UpworkConnector.presetName }
        return false
    }
}

public enum McpOAuthSubmission {
    public static let method = "auth.submit_oauth_tokens"

    public static func params(service: String, grant: McpOAuthGrant) -> JSONValue {
        var params: [String: JSONValue] = [
            "service": .string(service),
            "client_id": .string(grant.clientID),
            "redirect_uri": .string(grant.redirectURI),
            "token_endpoint": .string(grant.tokenEndpoint.absoluteString),
            "issuer": .string(grant.issuer),
            "access_token": .string(grant.accessToken.reveal()),
        ]
        if let refresh = grant.refreshToken { params["refresh_token"] = .string(refresh.reveal()) }
        if let expiresIn = grant.expiresIn { params["expires_in"] = .int(expiresIn) }
        if let scope = grant.scope { params["scope"] = .string(scope) }
        if let tokenType = grant.tokenType { params["token_type"] = .string(tokenType) }
        return .object(params)
    }

    public static func submit(_ grant: McpOAuthGrant, service: String, rpc: any ConnectRPC) async throws {
        let result: JSONValue
        do {
            result = try await rpc.call(method, params(service: service, grant: grant))
        } catch is CancellationError {
            throw McpOAuthError.cancelled
        } catch {
            throw McpOAuthError.gatewayUnavailable
        }
        guard result["ok"]?.boolValue == true else {
            throw McpOAuthError.rejectedByGateway(readable(result["reason"]?.stringValue))
        }
    }

    static func readable(_ reason: String?) -> String? {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        switch text {
        case "not_oauth_service": return "Your Pal doesn't use this kind of sign-in for that app."
        case "server_mismatch": return "The sign-in was for a different app than the one set up on your Pal."
        case "invalid_request": return "Your Pal couldn't read the sign-in. Try again."
        case "save_failed": return "Your Pal couldn't save the sign-in. Try again."
        default: return String(text.prefix(200))
        }
    }
}

public struct McpNativeSignIn: Sendable {
    let flow: McpOAuthFlow
    let rpc: any ConnectRPC
    let service: String

    public init(flow: McpOAuthFlow, rpc: any ConnectRPC, service: String = UpworkConnector.service) {
        self.flow = flow
        self.rpc = rpc
        self.service = service
    }

    public func run() async throws {
        let grant = try await flow.authorize()
        try await McpOAuthSubmission.submit(grant, service: service, rpc: rpc)
    }
}

extension ConnectAppsService {
    func connectUpwork(_ app: ConnectApp) async throws {
        guard let nativeSignIn else { throw ConnectAppsError.signInOnMac }
        let alreadyAdded = app.state != .disconnected
        if !alreadyAdded {
            _ = try await call("mcp.servers.add", ["name": .string(UpworkConnector.presetName), "preset": .string(UpworkConnector.presetName)])
        }
        do {
            try await nativeSignIn.run()
        } catch {
            if !alreadyAdded { _ = try? await call("mcp.servers.remove", ["name": .string(UpworkConnector.presetName)]) }
            let failure = McpOAuthError.from(error)
            throw failure == .cancelled ? ConnectAppsError.cancelled : ConnectAppsError.signInFailed(failure.reason)
        }
    }
}
