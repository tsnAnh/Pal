import Foundation
import PalDiagnostics
import PalProtocol
import Synchronization

struct GoogleGateway: Sendable {
    let rpc: any ConnectRPC
    let diagnostics: Diagnostics

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await rpc.call(method, .object(params))
        } catch let error as CancellationError {
            throw error
        } catch {
            diagnostics.info("google", "\(method) failed: \(Diagnostics.describe(error))")
            throw GoogleWorkspaceError.from(error)
        }
    }

    func status(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> GoogleWorkspaceStatus {
        try Self.decodeStatus(try await call(method, params))
    }

    static func decodeStatus(_ value: JSONValue) throws -> GoogleWorkspaceStatus {
        guard let status = try? value.decoded(as: GoogleWorkspaceStatus.self) else { throw GoogleWorkspaceError.failed }
        return status
    }
}

public enum GoogleSignInOutcome: Sendable, Equatable {
    case signedIn(GoogleWorkspaceStatus)
    case tryAgain(String)
    case denied(String)
    case failed(String)
}

public struct GoogleWorkspaceService: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let gateway: GoogleGateway

    public var description: String { "<google workspace>" }
    public var debugDescription: String { "<google workspace>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public init(rpc: any ConnectRPC, diagnostics: Diagnostics = .silent) {
        gateway = GoogleGateway(rpc: rpc, diagnostics: diagnostics)
    }

    public func status() async throws -> GoogleWorkspaceStatus {
        try await gateway.status("google_workspace.status")
    }

    public func verify() async throws -> GoogleWorkspaceStatus {
        try await gateway.status("google_workspace.verify")
    }

    public func setClient(clientID: SecretString, clientSecret: SecretString) async throws -> GoogleWorkspaceStatus {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw GoogleWorkspaceError.invalidClient }
        return try await gateway.status(
            "google_workspace.client.set",
            ["client_id": .string(clientID.reveal()), "client_secret": .string(clientSecret.reveal())]
        )
    }

    public func signOut(removeSetup: Bool = false) async throws -> GoogleWorkspaceStatus {
        try await gateway.status("google_workspace.signout", ["remove_setup": .bool(removeSetup)])
    }

    public func beginSignIn(_ selection: GoogleScopeSelection) async throws -> GoogleSignInSession {
        guard !selection.isEmpty else { throw GoogleWorkspaceError.invalidServices }
        let started = try await gateway.call("google_workspace.signin.start", selection.startParams)
        guard let flowID = started["flow_id"]?.stringValue, !flowID.isEmpty else { throw GoogleWorkspaceError.failed }
        guard let link = started["auth_url"]?.stringValue.flatMap(URL.init(string:)), Self.isGoogleLink(link) else {
            _ = try? await gateway.call("google_workspace.signin.cancel", ["flow_id": .string(flowID)])
            throw GoogleWorkspaceError.failed
        }
        return GoogleSignInSession(flowID: flowID, authURL: link, gateway: gateway)
    }

    static func isGoogleLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com")
    }
}

public final class GoogleSignInSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Phase: Sendable { case open, submitting, closed }

    public let authURL: URL
    private let flowID: String
    private let gateway: GoogleGateway
    private let phase = Mutex<Phase>(.open)

    init(flowID: String, authURL: URL, gateway: GoogleGateway) {
        self.flowID = flowID
        self.authURL = authURL
        self.gateway = gateway
    }

    public var description: String { "<google sign-in>" }
    public var debugDescription: String { "<google sign-in>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public func submit(_ pasted: String) async -> GoogleSignInOutcome {
        let claimed = phase.withLock { (value: inout Phase) -> Bool in
            guard case .open = value else { return false }
            value = .submitting
            return true
        }
        guard claimed else { return .failed(GoogleWorkspaceError.signInEnded.reason) }
        let result: JSONValue
        do {
            result = try await gateway.call("google_workspace.signin.finish", ["flow_id": .string(flowID), "pasted": .string(pasted)])
        } catch {
            await cancel()
            return .failed(GoogleWorkspaceError.from(error).reason)
        }
        return await outcome(result)
    }

    public func cancel() async {
        let first = phase.withLock { (value: inout Phase) -> Bool in
            if case .closed = value { return false }
            value = .closed
            return true
        }
        guard first else { return }
        _ = try? await gateway.call("google_workspace.signin.cancel", ["flow_id": .string(flowID)])
    }

    private func outcome(_ result: JSONValue) async -> GoogleSignInOutcome {
        switch result["state"]?.stringValue {
        case "signed_in":
            close()
            return await signedIn(result["status"])
        case "retry":
            phase.withLock { (value: inout Phase) in
                if case .submitting = value { value = .open }
            }
            return .tryAgain(Self.message(result, fallback: "That address didn't work. Copy the address from the page that failed to load and paste it again."))
        case "denied":
            close()
            return .denied(Self.message(result, fallback: "Google access wasn't granted."))
        default:
            close()
            return .failed(Self.message(result, fallback: GoogleWorkspaceError.failed.reason))
        }
    }

    private func signedIn(_ embedded: JSONValue?) async -> GoogleSignInOutcome {
        if let embedded, let status = try? GoogleGateway.decodeStatus(embedded) { return .signedIn(status) }
        if let status = try? await gateway.status("google_workspace.status") { return .signedIn(status) }
        return .failed("You're signed in, but Pal couldn't read the account. Refresh to check.")
    }

    private func close() {
        phase.withLock { (value: inout Phase) in value = .closed }
    }

    private static func message(_ result: JSONValue, fallback: String) -> String {
        let text = result["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : String(text.prefix(200))
    }
}
