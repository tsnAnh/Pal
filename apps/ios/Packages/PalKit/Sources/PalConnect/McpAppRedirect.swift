import Foundation
import PalAuth
import PalProtocol
import PalTransport

public protocol CallbackAuthorizationBrowser: AuthorizationBrowser {
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL
}

public enum McpConnectOutcome: Sendable {
    case connected
    case paste(any McpPasteSigning)
}

enum McpOAuthRedirect: String, Sendable {
    case app
    case gateway
    case loopback
}

struct McpOAuthStart: Sendable {
    var flow: String
    var link: URL
    var redirect: McpOAuthRedirect?
}

extension ConnectAppsService {
    static let appCallbackScheme = "dev.tsnanh.hermes.bot"
    static let appRedirectURI = "\(appCallbackScheme):/mcp-oauth/callback"
    private static let unsupportedRedirectCode = 4001

    func negotiateOAuthStart(name: String, fallbackURI: String, clientID: String?, offerApp: Bool) async throws -> McpOAuthStart {
        if offerApp {
            do {
                return try await requestOAuthStart(name: name, fallbackURI: fallbackURI, clientID: clientID, offerApp: true)
            } catch let error as GatewayTransportError {
                guard case .rpc(let rpc) = error, rpc.code == Self.unsupportedRedirectCode else { throw Self.startFailure(error) }
            }
        }
        do {
            return try await requestOAuthStart(name: name, fallbackURI: fallbackURI, clientID: clientID, offerApp: false)
        } catch let error as GatewayTransportError {
            throw Self.startFailure(error)
        }
    }

    private func requestOAuthStart(name: String, fallbackURI: String, clientID: String?, offerApp: Bool) async throws -> McpOAuthStart {
        var params: [String: JSONValue] = ["name": .string(name)]
        if offerApp {
            params["client_redirect_uri"] = .string(Self.appRedirectURI)
            params["fallback_redirect_uri"] = .string(fallbackURI)
        } else {
            params["client_redirect_uri"] = .string(fallbackURI)
        }
        if let clientID { params["client_id"] = .string(clientID) }
        let started = try await rawCall("mcp.servers.oauth.start", params)
        guard let flow = started["session_id"]?.stringValue, let link = started["auth_url"]?.stringValue.flatMap(URL.init(string:)),
              link.scheme?.lowercased() == "https" || link.scheme?.lowercased() == "http"
        else { throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason) }
        return McpOAuthStart(flow: flow, link: link, redirect: started["redirect"]?.stringValue.flatMap(McpOAuthRedirect.init(rawValue:)))
    }

    private static func startFailure(_ error: GatewayTransportError) -> ConnectAppsError {
        guard case .rpc(let rpc) = error else { return .failed }
        if McpAdminApproval.isPending(rpc.data?["reason"]?.stringValue) { return .adminApprovalPending }
        return .signInRefused(McpSignInFailure.classify(rpc.message), GatewayFault(rpc, method: "mcp.servers.oauth.start"))
    }

    func signInMcp(
        name: String, platform: ConnectorPlatform, browser: any AuthorizationBrowser, clientID: String? = nil,
        rollback: (@Sendable () async -> Void)?
    ) async throws -> McpConnectOutcome {
        var listener: LoopbackRedirectListener?
        if platform.returnsAutomatically { listener = try await startLoopback() }
        defer { listener?.cancel() }
        let callbackBrowser = browser as? any CallbackAuthorizationBrowser
        let fallback = listener?.redirectURI ?? Self.pasteRedirectURI()
        let started = try await negotiateOAuthStart(name: name, fallbackURI: fallback, clientID: clientID, offerApp: callbackBrowser != nil)
        switch started.redirect {
        case .app:
            let url = try await authenticate(started, name: name, using: callbackBrowser)
            try await relayCallback(name: name, flow: started.flow, parameters: Self.callbackParameters(url))
        case .gateway:
            _ = try await authenticate(started, name: name, using: callbackBrowser)
            try await awaitApproval(name: name, flow: started.flow)
        case .loopback, nil:
            if let listener {
                try await completeLoopback(name: name, flow: started.flow, link: started.link, listener: listener, browser: browser)
            } else {
                return .paste(try await pasteSession(name: name, started: started, rollback: rollback))
            }
        }
        return .connected
    }

    func authenticate(_ started: McpOAuthStart, name: String, using callbackBrowser: (any CallbackAuthorizationBrowser)?) async throws -> URL {
        guard let callbackBrowser else {
            _ = try? await call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(started.flow)])
            throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason)
        }
        do {
            return try await callbackBrowser.authenticate(started.link, callbackScheme: Self.appCallbackScheme)
        } catch {
            throw await failedSignIn(name: name, flow: started.flow, error: error)
        }
    }

    func failedSignIn(name: String, flow: String, error: any Error) async -> ConnectAppsError {
        _ = try? await call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(flow)])
        if error is CancellationError || (error as? SignInError) == .cancelled { return .cancelled }
        return .signInFailed(McpOAuthError.from(error).reason)
    }

    func relayCallback(name: String, flow: String, parameters: [String: String]) async throws {
        var relay: [String: JSONValue] = ["name": .string(name), "session_id": .string(flow)]
        for key in ["code", "state", "error", "iss"] { if let value = parameters[key] { relay[key] = .string(value) } }
        let delivered = try await call("mcp.servers.oauth.callback", relay)
        if delivered["ok"]?.boolValue == false {
            throw ConnectAppsError.signInFailed(McpSignInFailure.classify(delivered["error_message"]?.stringValue).reason)
        }
        try await awaitApproval(name: name, flow: flow)
    }

    private static func callbackParameters(_ url: URL) -> [String: String] {
        var found: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value, found[item.name] == nil { found[item.name] = value }
        }
        return found
    }

    static func pasteRedirectURI() -> String {
        "http://127.0.0.1:\(UInt16.random(in: McpOAuthFlow.pasteRedirectPorts))\(LoopbackRedirectListener.callbackPath)"
    }
}
