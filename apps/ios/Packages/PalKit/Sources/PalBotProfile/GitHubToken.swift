import Foundation
import Observation
import PalProtocol
import PalTransport

public enum GitHubTokenState: Sendable, Equatable {
    case set
    case missing
    case invalid
    case expired
    case missingScopes
    case notConfigured
    case unknown

    init(wire: String?) {
        switch wire {
        case "set": self = .set
        case "missing": self = .missing
        case "invalid": self = .invalid
        case "expired": self = .expired
        case "missing_scopes": self = .missingScopes
        case "oauth_app_not_configured": self = .notConfigured
        default: self = .unknown
        }
    }
}

public struct GitHubTokenStatus: Sendable, Equatable {
    public let state: GitHubTokenState
    public let login: String?
    public let scopes: [String]
    public let missingScopes: [String]

    init(_ value: JSONValue) {
        state = GitHubTokenState(wire: value["state"]?.stringValue)
        login = Self.text(value["login"]?.stringValue)
        scopes = Self.list(value["scopes"])
        missingScopes = Self.list(value["missing_scopes"])
    }

    public var isSignedIn: Bool { state == .set }

    public var headline: String {
        switch state {
        case .set: login.map { "Signed in as \($0)" } ?? "Signed in"
        case .missing: "Not signed in"
        case .invalid: "Invalid"
        case .expired: "Expired"
        case .missingScopes: missingScopes.isEmpty ? "Missing scopes" : "Missing scopes: \(missingScopes.joined(separator: ", "))"
        case .notConfigured: "OAuth app not configured"
        case .unknown: "Unknown"
        }
    }

    public var detail: String? {
        scopes.isEmpty ? nil : "Scopes: \(scopes.joined(separator: ", "))"
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func list(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { text($0.stringValue) }
    }
}

public struct GitHubOAuthCode: Sendable, Equatable {
    public let sessionID: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    public let interval: Int

    init?(_ value: JSONValue) {
        guard let sessionID = value["session_id"]?.stringValue, !sessionID.isEmpty,
              let userCode = value["user_code"]?.stringValue, !userCode.isEmpty,
              let raw = value["verification_uri"]?.stringValue, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host()?.isEmpty == false
        else { return nil }
        self.sessionID = sessionID
        self.userCode = userCode
        verificationURL = url
        expiresIn = max(value["expires_in"]?.intValue ?? 900, 1)
        interval = max(value["interval"]?.intValue ?? 5, 1)
    }
}

public enum GitHubOAuthPoll: Sendable, Equatable {
    case pending(interval: Int?)
    case signedIn(login: String?)
    case denied
    case expired
    case organizationApproval
    case failed(message: String?)

    init(_ value: JSONValue) {
        let message = value["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch value["state"]?.stringValue {
        case "pending": self = .pending(interval: value["interval"]?.intValue.map { max($0, 1) })
        case "signed_in": self = .signedIn(login: value["login"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        case "denied": self = .denied
        case "expired": self = .expired
        case "org_approval_needed": self = .organizationApproval
        default: self = .failed(message: message)
        }
    }
}

public enum GitHubTokenFailure: Error, Sendable, Equatable {
    case unsupported
    case unavailable

    static func classify(_ error: any Error) -> GitHubTokenFailure {
        if let failure = error as? GitHubTokenFailure { return failure }
        if case GatewayTransportError.rpc(let rpc) = error, rpc.code == -32601 { return .unsupported }
        return .unavailable
    }
}

public struct GitHubTokenClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status() async throws -> GitHubTokenStatus {
        let result = try await perform("github.token.status")
        guard result.objectValue != nil else { throw GitHubTokenFailure.unavailable }
        return GitHubTokenStatus(result)
    }

    public func start() async throws -> GitHubOAuthCode {
        guard let code = GitHubOAuthCode(try await perform("github.oauth.start")) else { throw GitHubTokenFailure.unavailable }
        return code
    }

    public func poll(_ sessionID: String) async throws -> GitHubOAuthPoll {
        GitHubOAuthPoll(try await perform("github.oauth.poll", ["session_id": .string(sessionID)]))
    }

    public func cancel(_ sessionID: String) async {
        _ = try? await gateway.call("github.oauth.cancel", ["session_id": .string(sessionID)])
    }

    public func setClientID(_ clientID: String) async throws {
        _ = try await perform("github.oauth.set_client_id", ["client_id": .string(clientID)])
    }

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubTokenFailure.classify(error)
        }
    }
}

@MainActor
@Observable
public final class GitHubTokenModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case unsupported
        case unavailable
        case ready(GitHubTokenStatus)
    }

    public enum SignIn: Sendable, Equatable {
        case starting
        case code(GitHubOAuthCode)
        case signedIn(login: String?)
        case denied
        case expired
        case organizationApproval
        case failed(String)

        var isWaiting: Bool {
            switch self {
            case .starting, .code: true
            default: false
            }
        }
    }

    public enum ClientIDState: Sendable, Equatable {
        case idle
        case saving
        case saved
        case failed
    }

    static let startFailure = "We couldn't start sign-in. Please try again."
    static let checkFailure = "We couldn't check your sign-in. Please try again."
    static let didNotFinish = "Sign-in didn't finish."
    static let maxPollFailures = 3

    public private(set) var phase: Phase = .loading
    public private(set) var signIn: SignIn?
    public private(set) var clientIDState: ClientIDState = .idle
    @ObservationIgnored private let client: GitHubTokenClient
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

    public init(
        client: GitHubTokenClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    public var status: GitHubTokenStatus? {
        if case .ready(let status) = phase { status } else { nil }
    }

    public var headline: String {
        switch signIn {
        case .starting?, .code?: return "Waiting for approval"
        case .denied?: return "Denied"
        case .expired?: return "Expired"
        case .organizationApproval?: return "Organization approval needed"
        case .signedIn?, .failed?, nil: break
        }
        switch phase {
        case .loading: return "Checking…"
        case .unsupported: return "Not supported yet"
        case .unavailable: return "Unknown"
        case .ready(let status): return status.headline
        }
    }

    public var footnote: String? {
        if case .organizationApproval = signIn {
            return "An organization owner must approve Pal in the organization's settings, then sign in again."
        }
        switch phase {
        case .unsupported: return "This gateway does not support this yet."
        case .unavailable: return "Couldn't check GitHub. Refresh to try again."
        case .loading, .ready: return nil
        }
    }

    public var needsClientID: Bool { status?.state == .notConfigured }

    public var canSignIn: Bool {
        switch phase {
        case .unsupported, .loading: false
        case .unavailable: true
        case .ready(let status): status.state != .notConfigured
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            phase = .ready(try await client.status())
            switch signIn {
            case .denied?, .expired?, .organizationApproval?: signIn = nil
            default: break
            }
        } catch is CancellationError {
        } catch GitHubTokenFailure.unsupported {
            phase = .unsupported
        } catch {
            if status == nil { phase = .unavailable }
        }
    }

    public func saveClientID(_ text: String) async {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace), clientIDState != .saving else {
            clientIDState = .failed
            return
        }
        clientIDState = .saving
        do {
            try await client.setClientID(id)
            clientIDState = .saved
            await refresh()
        } catch is CancellationError {
            clientIDState = .idle
        } catch {
            clientIDState = .failed
        }
    }

    public func beginSignIn() async {
        guard canSignIn else { return }
        await endSession()
        signIn = .starting
        do {
            let code = try await client.start()
            signIn = .code(code)
            pollTask = Task { [weak self] in await self?.poll(code) }
        } catch is CancellationError {
            signIn = nil
        } catch GitHubTokenFailure.unsupported {
            signIn = nil
            phase = .unsupported
        } catch {
            signIn = .failed(Self.startFailure)
        }
    }

    public func closeSignIn() async {
        await endSession()
        switch signIn {
        case .starting?, .code?, .signedIn?, .failed?: signIn = nil
        case .denied?, .expired?, .organizationApproval?, nil: break
        }
    }

    private func endSession() async {
        let task = pollTask
        pollTask = nil
        task?.cancel()
        if case .code(let code) = signIn { await client.cancel(code.sessionID) }
        await task?.value
    }

    private func poll(_ code: GitHubOAuthCode) async {
        var interval = code.interval
        var waited = 0
        var failures = 0
        while !Task.isCancelled {
            do {
                try await sleep(.seconds(interval))
            } catch {
                return
            }
            waited += interval
            do {
                let result = try await client.poll(code.sessionID)
                failures = 0
                switch result {
                case .pending(let next):
                    if let next { interval = next }
                    if waited >= code.expiresIn { finish(.expired) }
                case .signedIn(let login):
                    finish(.signedIn(login: login))
                    await refresh()
                case .denied: finish(.denied)
                case .expired: finish(.expired)
                case .organizationApproval: finish(.organizationApproval)
                case .failed(let message): finish(.failed(message ?? Self.didNotFinish))
                }
                if case .code = signIn {} else { return }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                if failures >= Self.maxPollFailures {
                    finish(.failed(Self.checkFailure))
                    return
                }
            }
        }
    }

    private func finish(_ outcome: SignIn) {
        guard !Task.isCancelled, case .code = signIn else { return }
        signIn = outcome
    }
}
