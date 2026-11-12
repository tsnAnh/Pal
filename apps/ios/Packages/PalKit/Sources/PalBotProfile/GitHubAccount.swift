import Foundation
import Observation
import PalProtocol
import PalTransport

public enum GitHubGitProtocol: Sendable, Equatable {
    case https
    case ssh
    case unset
    case unknown

    init(wire: String?) {
        switch wire {
        case "https": self = .https
        case "ssh": self = .ssh
        case "unset": self = .unset
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .https: "Git uses HTTPS"
        case .ssh: "Git uses SSH"
        case .unset: "Git has no preferred way to connect"
        case .unknown: "Git connection unknown"
        }
    }
}

public enum GitHubFix: Sendable, Equatable {
    case signIn
    case gitProtocol

    init?(wire: String?) {
        switch wire {
        case "github.signin": self = .signIn
        case "github.git_protocol.fix": self = .gitProtocol
        default: return nil
        }
    }

    public var actionTitle: String {
        switch self {
        case .signIn: "Sign in"
        case .gitProtocol: "Switch to HTTPS"
        }
    }
}

public struct GitHubProblem: Sendable, Equatable, Identifiable {
    public let id: String
    public let fix: GitHubFix?
    public let message: String

    init(_ value: JSONValue) {
        let id = value["id"]?.stringValue ?? ""
        self.id = id
        fix = GitHubFix(wire: value["fix"]?.stringValue)
        switch id {
        case "gh_signed_out": message = "GitHub is not signed in. Bots can't open pull requests until you sign in."
        case "git_ssh_unknown_host": message = "Downloads from GitHub over SSH may fail on this host. Switch to HTTPS."
        default: message = value["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "GitHub reported a problem on this host."
        }
    }
}

public struct GitHubStatus: Sendable, Equatable {
    public let signedIn: Bool?
    public let login: String?
    public let gitProtocol: GitHubGitProtocol
    public let problems: [GitHubProblem]

    init(_ value: JSONValue) {
        signedIn = value["signed_in"]?.boolValue
        login = value["login"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        gitProtocol = GitHubGitProtocol(wire: value["git_protocol"]?.stringValue)
        problems = (value["problems"]?.arrayValue ?? []).map(GitHubProblem.init)
    }

    public var accountLine: String {
        switch signedIn {
        case true?: login.map { "Signed in as \($0)" } ?? "Signed in"
        case false?: "Not signed in"
        case nil: "Unknown"
        }
    }
}

public struct GitHubSignInCode: Sendable, Equatable {
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

public enum GitHubPoll: Sendable, Equatable {
    case pending
    case signedIn(login: String?)
    case expired
    case failed(message: String?)

    init(_ value: JSONValue) {
        switch value["state"]?.stringValue {
        case "pending": self = .pending
        case "signed_in": self = .signedIn(login: value["login"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        case "expired": self = .expired
        default: self = .failed(message: value["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

public enum GitHubFailure: Error, Sendable, Equatable {
    case unsupported
    case unavailable

    static func classify(_ error: any Error) -> GitHubFailure {
        if let failure = error as? GitHubFailure { return failure }
        if case GatewayTransportError.rpc(let rpc) = error, rpc.code == -32601 { return .unsupported }
        return .unavailable
    }
}

public struct GitHubClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status() async throws -> GitHubStatus {
        try await statusCall("github.status")
    }

    public func fixGitProtocol() async throws -> GitHubStatus {
        try await statusCall("github.git_protocol.fix")
    }

    public func startSignIn() async throws -> GitHubSignInCode {
        let result = try await perform("github.signin.start")
        guard let code = GitHubSignInCode(result) else { throw GitHubFailure.unavailable }
        return code
    }

    public func poll(_ sessionID: String) async throws -> GitHubPoll {
        GitHubPoll(try await perform("github.signin.poll", ["session_id": .string(sessionID)]))
    }

    public func cancel(_ sessionID: String) async {
        _ = try? await gateway.call("github.signin.cancel", ["session_id": .string(sessionID)])
    }

    private func statusCall(_ method: String) async throws -> GitHubStatus {
        let result = try await perform(method)
        guard result.objectValue != nil else { throw GitHubFailure.unavailable }
        return GitHubStatus(result)
    }

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubFailure.classify(error)
        }
    }
}

@MainActor
@Observable
public final class GitHubAccountModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case unsupported
        case unavailable
        case ready(GitHubStatus)
    }

    public enum FixState: Sendable, Equatable {
        case idle
        case working
        case saved
        case failed
    }

    public enum SignIn: Sendable, Equatable {
        case starting
        case code(GitHubSignInCode)
        case signedIn(login: String?)
        case expired
        case failed(String)
    }

    static let startFailure = "We couldn't start sign-in. Please try again."
    static let checkFailure = "We couldn't check your sign-in. Please try again."
    static let didNotFinish = "Sign-in didn't finish."
    static let maxPollFailures = 3

    public private(set) var phase: Phase = .loading
    public private(set) var fix: FixState = .idle
    public private(set) var signIn: SignIn?

    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?

    public init(
        client: GitHubClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    public var problems: [GitHubProblem] {
        if case .ready(let status) = phase { status.problems } else { [] }
    }

    public func refresh() async {
        do {
            phase = .ready(try await client.status())
        } catch is CancellationError {
        } catch {
            phase = GitHubFailure.classify(error) == .unsupported ? .unsupported : .unavailable
        }
    }

    public func perform(_ action: GitHubFix) async {
        switch action {
        case .signIn: await beginSignIn()
        case .gitProtocol: await fixGitProtocol()
        }
    }

    public func fixGitProtocol() async {
        guard fix != .working else { return }
        fix = .working
        do {
            phase = .ready(try await client.fixGitProtocol())
            fix = .saved
        } catch is CancellationError {
            fix = .idle
        } catch {
            fix = .failed
        }
    }

    public func beginSignIn() async {
        stopPolling()
        signIn = .starting
        do {
            let code = try await client.startSignIn()
            signIn = .code(code)
            pollTask = Task { [weak self] in await self?.poll(code) }
        } catch is CancellationError {
            signIn = nil
        } catch {
            signIn = .failed(Self.startFailure)
        }
    }

    public func closeSignIn() async {
        let pending: String? = if case .code(let code) = signIn { code.sessionID } else { nil }
        stopPolling()
        signIn = nil
        if let pending { await client.cancel(pending) }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll(_ code: GitHubSignInCode) async {
        var waited = 0
        var failures = 0
        while !Task.isCancelled {
            do {
                try await sleep(.seconds(code.interval))
                waited += code.interval
                switch try await client.poll(code.sessionID) {
                case .pending:
                    failures = 0
                    if waited >= code.expiresIn { return finish(.expired, code) }
                case .signedIn(let login):
                    finish(.signedIn(login: login), code)
                    await refresh()
                    return
                case .expired: return finish(.expired, code)
                case .failed(let message): return finish(.failed(message ?? Self.didNotFinish), code)
                }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                if failures >= Self.maxPollFailures || GitHubFailure.classify(error) == .unsupported {
                    return finish(.failed(Self.checkFailure), code)
                }
            }
        }
    }

    private func finish(_ result: SignIn, _ code: GitHubSignInCode) {
        guard !Task.isCancelled, case .code(let showing) = signIn, showing == code else { return }
        signIn = result
    }
}
