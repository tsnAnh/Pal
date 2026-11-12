import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization

public enum UpworkConnector {
    public static let presetName = "upwork"
    public static let service = "mcp:upwork"
    public static let serverURL = URL(string: "https://mcp.upwork.com/mcp")!
}

extension ConnectApp {
    public var requiresAppSignIn: Bool {
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

public enum McpPasteOutcome: Sendable, Equatable {
    case signedIn
    case tryAgain(String)
    case failed(String)
}

public final class McpPasteSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let handshake: McpOAuthHandshake
    private let flow: McpOAuthFlow
    private let rpc: any ConnectRPC
    private let service: String
    private let rollback: (@Sendable () async -> Void)?
    private let settled = Mutex<Bool>(false)

    init(handshake: McpOAuthHandshake, flow: McpOAuthFlow, rpc: any ConnectRPC, service: String, rollback: (@Sendable () async -> Void)?) {
        self.handshake = handshake
        self.flow = flow
        self.rpc = rpc
        self.service = service
        self.rollback = rollback
    }

    public var authorizeURL: URL { handshake.authorizeURL }
    public var description: String { "<paste sign-in>" }
    public var debugDescription: String { "<paste sign-in>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public func submit(_ pasted: String) async -> McpPasteOutcome {
        do {
            let grant = try await flow.complete(handshake, pasted: pasted)
            try await McpOAuthSubmission.submit(grant, service: service, rpc: rpc)
            settled.withLock { (value: inout Bool) in value = true }
            return .signedIn
        } catch {
            let failure = McpOAuthError.from(error)
            if case .pasted(let paste) = failure, paste.keepsAttemptOpen { return .tryAgain(failure.reason) }
            await abandon()
            return .failed(failure.reason)
        }
    }

    public func cancel() async {
        await abandon()
    }

    private func abandon() async {
        handshake.cancel()
        let first = settled.withLock { (value: inout Bool) -> Bool in
            let wasSettled = value
            value = true
            return !wasSettled
        }
        if first { await rollback?() }
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

    public func beginPaste(rollback: (@Sendable () async -> Void)? = nil) async throws -> McpPasteSession {
        let handshake = try await flow.beginPasted()
        return McpPasteSession(handshake: handshake, flow: flow, rpc: rpc, service: service, rollback: rollback)
    }
}

extension ConnectAppsService {
    func connectUpwork(_ app: ConnectApp) async throws {
        guard let nativeSignIn else { throw ConnectAppsError.unavailable }
        let added = try await addUpworkServer(if: app.state == .disconnected)
        let alreadyAdded = !added
        do {
            try await nativeSignIn.run()
        } catch {
            if !alreadyAdded { _ = try? await call("mcp.servers.remove", ["name": .string(UpworkConnector.presetName)]) }
            let failure = McpOAuthError.from(error)
            throw failure == .cancelled ? ConnectAppsError.cancelled : ConnectAppsError.signInFailed(failure.reason)
        }
    }

    private func addUpworkServer(if needed: Bool) async throws -> Bool {
        guard needed else { return false }
        do {
            _ = try await rawCall("mcp.servers.add", ["name": .string(UpworkConnector.presetName), "preset": .string(UpworkConnector.presetName)])
            return true
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error else { throw ConnectAppsError.signInFailed(McpOAuthError.gatewayUnavailable.reason) }
            if rpc.code == 4090 { return false }
            if Self.map(error) == .signInRequired { throw ConnectAppsError.signInRequired }
            throw ConnectAppsError.signInFailed(McpOAuthError.serverAddFailed(McpOAuthSubmission.readable(rpc.message)).reason)
        }
    }

    public func beginUpworkPaste(_ app: ConnectApp) async throws -> McpPasteSession {
        guard let nativeSignIn else { throw ConnectAppsError.unavailable }
        let adding = try await addUpworkServer(if: app.state == .disconnected)
        let service = self
        let remove: (@Sendable () async -> Void)?
        if adding {
            remove = { @Sendable in _ = try? await service.call("mcp.servers.remove", ["name": .string(UpworkConnector.presetName)]) }
        } else {
            remove = nil
        }
        do {
            return try await nativeSignIn.beginPaste(rollback: remove)
        } catch {
            await remove?()
            throw ConnectAppsError.signInFailed(McpOAuthError.from(error).reason)
        }
    }
}
