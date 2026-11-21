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

    public var code: String {
        switch self {
        case .registrationRejected: "invalid_client_metadata"
        case .redirectRefused: "invalid_redirect_uri"
        case .denied: "access_denied"
        case .expired: "sign_in_expired"
        case .unsupportedGrant: "unsupported_grant_type"
        case .other: "sign_in_failed"
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

public enum McpAdminApproval {
    public static let message = "An admin of your organisation needs to approve Pal."
    static let wireReason = "ADMIN_APPROVAL_PENDING"

    static func isPending(_ reason: String?) -> Bool { reason == wireReason }
}

enum McpDeviceSignIn {
    static let wireReason = "SIGNIN_ON_DEVICE"
    static let faultReason = "signin_on_device"

    static func isWireReason(_ reason: String?) -> Bool { reason == wireReason }

    static func isRefusal(_ fault: GatewayFault) -> Bool { fault.reason == faultReason }

    static func refusal(_ rpc: RPCError, method: String) -> GatewayFault {
        GatewayFault(code: rpc.code, reason: faultReason, trace: rpc.trace ?? .random(), method: method, source: .gateway, gatewayVersion: rpc.gatewayVersion)
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
    private let account: String?
    private let state: SecretString
    private let redirect: URL
    private let rollback: (@Sendable () async -> Void)?
    private let settled = Mutex<Bool>(false)
    private let relayed = Mutex<Bool>(false)

    init(
        service: ConnectAppsService, name: String, flow: String, account: String? = nil, authorizeURL: URL, state: String, redirect: URL,
        rollback: (@Sendable () async -> Void)?
    ) {
        self.service = service
        self.name = name
        self.flow = flow
        self.account = account
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
            var relay = service.oauthSessionParams(name: name, flow: flow, account: account)
            relay["code"] = .string(code)
            relay["state"] = .string(state.reveal())
            let result = try await service.call("mcp.servers.oauth.callback", relay)
            if result["ok"]?.boolValue == false {
                await abandon()
                return .failed(McpSignInFailure.classify(result["error_message"]?.stringValue).reason)
            }
            try await service.awaitApproval(name: name, flow: flow, account: account)
            settled.withLock { (value: inout Bool) in value = true }
            return .signedIn
        } catch {
            await abandon()
            if case ConnectAppsError.adminApprovalPending = error { return .adminApprovalPending }
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
        await service.cancelSignIn(name: name, flow: flow, account: account)
        await rollback?()
    }
}

extension ConnectAppsService {
    func awaitApproval(name: String, flow: String, account: String? = nil) async throws {
        for _ in 0..<timing.pollAttempts {
            let poll = try await call("mcp.servers.oauth.poll", oauthSessionParams(name: name, flow: flow, account: account))
            switch poll["status"]?.stringValue {
            case "approved": return
            case "error":
                if McpAdminApproval.isPending(poll["reason"]?.stringValue) { throw ConnectAppsError.adminApprovalPending }
                throw ConnectAppsError.signInFailed(McpSignInFailure.classify(poll["error_message"]?.stringValue).reason)
            default: try await Task.sleep(for: timing.pollInterval)
            }
        }
        await cancelSignIn(name: name, flow: flow, account: account)
        throw ConnectAppsError.signInFailed(McpSignInFailure.expired.reason)
    }

    public func signInMcp(
        _ app: ConnectApp, platform: ConnectorPlatform, account: ConnectorAccountTarget? = nil,
        onStarted: (@Sendable (Bool) async -> Void)? = nil
    ) async throws -> McpConnectOutcome {
        let name: String
        let adding: Bool
        switch app.source {
        case .mcp(let preset, let requires) where requires.isEmpty:
            name = preset
            adding = app.state == .disconnected
            if adding { _ = try await call("mcp.servers.add", ["name": .string(name), "preset": .string(name)]) }
        case .catalog(let entry) where entry.method == .mcpOAuth:
            name = entry.slug
            adding = try await addCatalogServer(entry)
        default: throw ConnectAppsError.failed
        }
        let service = self
        let rollback: (@Sendable () async -> Void)? = adding ? { @Sendable in _ = try? await service.call("mcp.servers.remove", ["name": .string(name)]) } : nil
        do {
            return try await signInMcp(
                name: name, platform: platform, browser: browser, account: account, onStarted: onStarted, rollback: rollback
            )
        } catch {
            await rollback?()
            throw error
        }
    }

    func pasteSession(name: String, started: McpOAuthStart, rollback: (@Sendable () async -> Void)?) async throws -> any McpPasteSigning {
        let query = URLComponents(url: started.link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let state = query.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              let redirect = query.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:))
        else {
            await cancelSignIn(name: name, flow: started.flow, account: started.account)
            throw ConnectAppsError.signInFailed(McpSignInFailure.other.reason)
        }
        return McpGatewayPasteSession(
            service: self, name: name, flow: started.flow, account: started.account, authorizeURL: started.link, state: state,
            redirect: redirect, rollback: rollback
        )
    }
}
