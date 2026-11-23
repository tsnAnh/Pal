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
    var account: String?
    var privateWindowHint = false
}

extension ConnectAppsService {
    private static let unsupportedRedirectCode = 4001
    static let accountExistsCode = 4090

    func negotiateOAuthStart(
        name: String, fallbackURI: String, clientID: String?, offerApp: Bool, account: ConnectorAccountTarget? = nil
    ) async throws -> McpOAuthStart {
        if offerApp {
            do {
                return try await requestOAuthStart(name: name, fallbackURI: fallbackURI, clientID: clientID, offerApp: true, account: account)
            } catch let error as GatewayTransportError {
                guard case .rpc(let rpc) = error, rpc.code == Self.unsupportedRedirectCode else { throw Self.startFailure(error) }
            }
        }
        do {
            return try await requestOAuthStart(name: name, fallbackURI: fallbackURI, clientID: clientID, offerApp: false, account: account)
        } catch let error as GatewayTransportError {
            throw Self.startFailure(error)
        }
    }

    private func requestOAuthStart(
        name: String, fallbackURI: String, clientID: String?, offerApp: Bool, account: ConnectorAccountTarget?
    ) async throws -> McpOAuthStart {
        var params: [String: JSONValue] = ["name": .string(name)]
        if offerApp {
            params["client_redirect_uri"] = .string(urlScheme.mcpRedirectURI)
            params["fallback_redirect_uri"] = .string(fallbackURI)
        } else {
            params["client_redirect_uri"] = .string(fallbackURI)
        }
        if let clientID { params["client_id"] = .string(clientID) }
        if let account { params = account.scoping(params, create: true) }
        let started = try await rawCall("mcp.servers.oauth.start", params)
        guard let flow = started["session_id"]?.stringValue, let link = started["auth_url"]?.stringValue.flatMap(URL.init(string:)),
              link.scheme?.lowercased() == "https" || link.scheme?.lowercased() == "http"
        else { throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason) }
        return McpOAuthStart(
            flow: flow, link: link, redirect: started["redirect"]?.stringValue.flatMap(McpOAuthRedirect.init(rawValue:)),
            account: account?.name, privateWindowHint: started["private_window_hint"]?.boolValue ?? false
        )
    }

    private static func startFailure(_ error: GatewayTransportError) -> ConnectAppsError {
        guard case .rpc(let rpc) = error else { return .failed }
        if rpc.code == accountExistsCode { return .accountName(.taken) }
        if McpAdminApproval.isPending(rpc.data?["reason"]?.stringValue) { return .adminApprovalPending }
        if McpDeviceSignIn.isWireReason(rpc.data?["reason"]?.stringValue) {
            return .signInRefused(McpSignInFailure.classify(rpc.message), McpDeviceSignIn.refusal(rpc, method: "mcp.servers.oauth.start"))
        }
        return .signInRefused(McpSignInFailure.classify(rpc.message), GatewayFault(rpc, method: "mcp.servers.oauth.start"))
    }

    func signInMcp(
        name: String, platform: ConnectorPlatform, browser: any AuthorizationBrowser, clientID: String? = nil,
        account: ConnectorAccountTarget? = nil, onStarted: (@Sendable (Bool) async -> Void)? = nil,
        rollback: (@Sendable () async -> Void)?
    ) async throws -> McpConnectOutcome {
        var listener: LoopbackRedirectListener?
        if platform.returnsAutomatically { listener = try await startLoopback() }
        defer { listener?.cancel() }
        let callbackBrowser = browser as? any CallbackAuthorizationBrowser
        let fallback = listener?.redirectURI ?? Self.pasteRedirectURI()
        let started = try await negotiateOAuthStart(
            name: name, fallbackURI: fallback, clientID: clientID, offerApp: callbackBrowser != nil, account: account
        )
        await onStarted?(started.privateWindowHint)
        switch started.redirect {
        case .app:
            let url = try await authenticate(started, name: name, using: callbackBrowser)
            try await relayCallback(name: name, flow: started.flow, parameters: Self.callbackParameters(url), account: started.account)
        case .gateway:
            _ = try await authenticate(started, name: name, using: callbackBrowser)
            try await awaitApproval(name: name, flow: started.flow, account: started.account)
        case .loopback, nil:
            if let listener {
                try await completeLoopback(
                    name: name, flow: started.flow, link: started.link, listener: listener, browser: browser, account: started.account
                )
            } else {
                return .paste(try await pasteSession(name: name, started: started, rollback: rollback))
            }
        }
        return .connected
    }

    func authenticate(_ started: McpOAuthStart, name: String, using callbackBrowser: (any CallbackAuthorizationBrowser)?) async throws -> URL {
        guard let callbackBrowser else {
            await cancelSignIn(name: name, flow: started.flow, account: started.account)
            throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason)
        }
        do {
            return try await callbackBrowser.authenticate(started.link, callbackScheme: urlScheme.rawValue)
        } catch {
            throw await failedSignIn(name: name, flow: started.flow, error: error, account: started.account)
        }
    }

    func oauthSessionParams(name: String, flow: String, account: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["name": .string(name), "session_id": .string(flow)]
        if let account { params["account"] = .string(account) }
        return params
    }

    func cancelSignIn(name: String, flow: String, account: String?) async {
        _ = try? await call("mcp.servers.oauth.cancel", oauthSessionParams(name: name, flow: flow, account: account))
    }

    func failedSignIn(name: String, flow: String, error: any Error, account: String? = nil) async -> ConnectAppsError {
        await cancelSignIn(name: name, flow: flow, account: account)
        if error is CancellationError || (error as? SignInError) == .cancelled { return .cancelled }
        return .signInFailed(McpOAuthError.from(error).reason)
    }

    func relayCallback(name: String, flow: String, parameters: [String: String], account: String? = nil) async throws {
        var relay = oauthSessionParams(name: name, flow: flow, account: account)
        for key in ["code", "state", "error", "iss"] { if let value = parameters[key] { relay[key] = .string(value) } }
        let delivered = try await call("mcp.servers.oauth.callback", relay)
        if delivered["ok"]?.boolValue == false {
            throw ConnectAppsError.signInFailed(McpSignInFailure.classify(delivered["error_message"]?.stringValue).reason)
        }
        try await awaitApproval(name: name, flow: flow, account: account)
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
