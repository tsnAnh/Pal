import Foundation
import PalAuth
import PalProtocol
import PalTransport
import Synchronization

public enum McpConnectRoute: Sendable, Equatable {
    case apiKey
    case loopback
    case pasteAddress

    public static func decide(requires: [String], platform: ConnectorPlatform) -> McpConnectRoute {
        if !requires.isEmpty { return .apiKey }
        return platform.returnsAutomatically ? .loopback : .pasteAddress
    }
}

public enum McpSignInFailure: Sendable, Equatable, CaseIterable {
    case registrationRejected
    case redirectRefused
    case denied
    case expired
    case unsupportedGrant
    case other

    public var reason: String {
        switch self {
        case .registrationRejected: "The sign-in service didn't accept Pal."
        case .redirectRefused: "The sign-in service doesn't allow signing in this way."
        case .denied: "Access was not granted."
        case .expired: "This sign-in expired. Try again."
        case .unsupportedGrant: "The sign-in service doesn't support this kind of sign-in."
        case .other: "The sign-in couldn't be completed. Try again."
        }
    }

    public static func classify(_ gatewayText: String?) -> McpSignInFailure {
        let text = (gatewayText ?? "").lowercased()
        if text.contains("unsupported") { return .unsupportedGrant }
        if text.contains("redirect") { return .redirectRefused }
        if text.contains("denied") { return .denied }
        if ["invalid_grant", "expired", "state", "timed out", "timeout"].contains(where: text.contains) { return .expired }
        if ["registration", "invalid_client", "client"].contains(where: text.contains) { return .registrationRejected }
        return .other
    }
}

public protocol McpPasteSigning: Sendable {
    var authorizeURL: URL { get }
    func submit(_ pasted: String) async -> McpPasteOutcome
    func cancel() async
}

extension McpPasteSession: McpPasteSigning {}

public final class McpGatewayPasteSession: McpPasteSigning, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let authorizeURL: URL
    private let service: ConnectAppsService
    private let name: String
    private let flow: String
    private let state: SecretString
    private let redirect: URL
    private let rollback: (@Sendable () async -> Void)?
    private let settled = Mutex<Bool>(false)
    private let relayed = Mutex<Bool>(false)

    init(
        service: ConnectAppsService, name: String, flow: String, authorizeURL: URL, state: String, redirect: URL,
        rollback: (@Sendable () async -> Void)?
    ) {
        self.service = service
        self.name = name
        self.flow = flow
        self.authorizeURL = authorizeURL
        self.state = SecretString(state)
        self.redirect = redirect
        self.rollback = rollback
    }

    public var description: String { "<gateway paste sign-in>" }
    public var debugDescription: String { "<gateway paste sign-in>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public func submit(_ pasted: String) async -> McpPasteOutcome {
        switch PastedAuthorization.parse(pasted, expectedState: state.reveal(), expectedRedirect: redirect) {
        case .failure(let failure):
            if failure.keepsAttemptOpen { return .tryAgain(failure.userText) }
            await abandon()
            return .failed(failure.userText)
        case .success(let code):
            let first = relayed.withLock { (value: inout Bool) -> Bool in
                let was = value
                value = true
                return !was
            }
            guard first else { return .failed(McpOAuthError.handshakeUsed.reason) }
            return await relay(code: code)
        }
    }

    public func cancel() async {
        await abandon()
    }

    private func relay(code: String) async -> McpPasteOutcome {
        do {
            let result = try await service.call(
                "mcp.servers.oauth.callback",
                ["name": .string(name), "session_id": .string(flow), "code": .string(code), "state": .string(state.reveal())]
            )
            if result["ok"]?.boolValue == false {
                await abandon()
                return .failed(McpSignInFailure.classify(result["error_message"]?.stringValue).reason)
            }
            try await service.awaitApproval(name: name, flow: flow)
            settled.withLock { (value: inout Bool) in value = true }
            return .signedIn
        } catch {
            await abandon()
            if case ConnectAppsError.signInFailed(let reason) = error { return .failed(reason) }
            return .failed(McpSignInFailure.other.reason)
        }
    }

    private func abandon() async {
        let first = settled.withLock { (value: inout Bool) -> Bool in
            let was = value
            value = true
            return !was
        }
        guard first else { return }
        _ = try? await service.call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(flow)])
        await rollback?()
    }
}

extension ConnectAppsService {
    func startOAuth(name: String, redirectURI: String, clientID: String?) async throws -> (flow: String, link: URL) {
        var params: [String: JSONValue] = ["name": .string(name), "client_redirect_uri": .string(redirectURI)]
        if let clientID { params["client_id"] = .string(clientID) }
        let started: JSONValue
        do {
            started = try await rawCall("mcp.servers.oauth.start", params)
        } catch let error as GatewayTransportError {
            if case .rpc(let rpc) = error, ConnectAppsService.map(error) != .signInRequired {
                throw ConnectAppsError.signInFailed(McpSignInFailure.classify(rpc.message).reason)
            }
            throw ConnectAppsService.map(error)
        }
        guard let flow = started["session_id"]?.stringValue, let link = started["auth_url"]?.stringValue.flatMap(URL.init(string:)),
              link.scheme?.lowercased() == "https" || link.scheme?.lowercased() == "http"
        else { throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason) }
        return (flow, link)
    }

    func awaitApproval(name: String, flow: String) async throws {
        for _ in 0..<timing.pollAttempts {
            let poll = try await call("mcp.servers.oauth.poll", ["name": .string(name), "session_id": .string(flow)])
            switch poll["status"]?.stringValue {
            case "approved": return
            case "error": throw ConnectAppsError.signInFailed(McpSignInFailure.classify(poll["error_message"]?.stringValue).reason)
            default: try await Task.sleep(for: timing.pollInterval)
            }
        }
        throw ConnectAppsError.signInFailed(McpSignInFailure.expired.reason)
    }

    public func beginMcpPaste(_ app: ConnectApp) async throws -> any McpPasteSigning {
        guard case .mcp(let name, let requires) = app.source, requires.isEmpty, !app.requiresAppSignIn else { throw ConnectAppsError.failed }
        let adding = app.state == .disconnected
        if adding {
            _ = try await call("mcp.servers.add", ["name": .string(name), "preset": .string(name)])
        }
        let service = self
        let rollback: (@Sendable () async -> Void)? = adding ? { @Sendable in _ = try? await service.call("mcp.servers.remove", ["name": .string(name)]) } : nil
        do {
            let port = UInt16.random(in: McpOAuthFlow.pasteRedirectPorts)
            let started = try await startOAuth(name: name, redirectURI: "http://127.0.0.1:\(port)\(LoopbackRedirectListener.callbackPath)", clientID: nil)
            let query = URLComponents(url: started.link, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let state = query.first(where: { $0.name == "state" })?.value, !state.isEmpty,
                  let redirect = query.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:))
            else {
                _ = try? await call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(started.flow)])
                throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason)
            }
            return McpGatewayPasteSession(
                service: self, name: name, flow: started.flow, authorizeURL: started.link, state: state, redirect: redirect, rollback: rollback
            )
        } catch {
            await rollback?()
            throw error
        }
    }
}
