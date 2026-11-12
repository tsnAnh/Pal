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
    case unknown

    init(wire: String?) {
        switch wire {
        case "set": self = .set
        case "missing": self = .missing
        case "invalid": self = .invalid
        case "expired": self = .expired
        case "missing_scopes": self = .missingScopes
        default: self = .unknown
        }
    }
}

public struct GitHubTokenStatus: Sendable, Equatable {
    public static let requiredScopes = ["repo", "workflow"]

    public let state: GitHubTokenState
    public let login: String?
    public let scopes: [String]
    public let missingScopes: [String]
    public let expiresAt: Date?

    init(_ value: JSONValue) {
        state = GitHubTokenState(wire: value["state"]?.stringValue)
        login = Self.text(value["login"]?.stringValue)
        scopes = Self.list(value["scopes"])
        missingScopes = Self.list(value["missing_scopes"])
        expiresAt = value["expires_at"]?.stringValue.flatMap(Self.date)
    }

    public var isSet: Bool { state == .set }

    public var headline: String {
        switch state {
        case .set: login.map { "Set, signed in as \($0)" } ?? "Set"
        case .missing: "Missing"
        case .invalid: "Invalid"
        case .expired: "Expired"
        case .missingScopes: missingScopes.isEmpty ? "Missing scopes" : "Missing scopes: \(missingScopes.joined(separator: ", "))"
        case .unknown: "Unknown"
        }
    }

    public var detail: String? {
        var parts: [String] = []
        if !scopes.isEmpty { parts.append("Scopes: \(scopes.joined(separator: ", "))") }
        if let expiresAt { parts.append("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func list(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { text($0.stringValue) }
    }

    private static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}

public enum GitHubTokenFailure: Error, Sendable, Equatable {
    case invalid
    case expired
    case missingScopes([String])
    case unreachable
    case applyFailed
    case unsupported
    case unavailable

    static let unchanged = " Your current token was not changed."

    public var message: String {
        switch self {
        case .invalid: "GitHub did not accept this token." + Self.unchanged
        case .expired: "This token has expired. Create a new one." + Self.unchanged
        case .missingScopes(let names):
            "The token needs repo and workflow" + (names.isEmpty ? "." : "; missing: \(names.joined(separator: ", ")).") + Self.unchanged
        case .unreachable: "Couldn't reach GitHub. Check the connection and try again." + Self.unchanged
        case .applyFailed: "The token was accepted but couldn't be saved on this machine." + Self.unchanged
        case .unsupported: "This gateway does not support this yet."
        case .unavailable: "Couldn't save the token. Try again." + Self.unchanged
        }
    }

    init?(typed value: JSONValue?, fallbackCode: String? = nil) {
        let missing = (value?["missing_scopes"]?.arrayValue ?? []).compactMap(\.stringValue)
        switch value?["code"]?.stringValue ?? value?["reason"]?.stringValue ?? fallbackCode {
        case "invalid": self = .invalid
        case "expired": self = .expired
        case "missing_scopes": self = .missingScopes(missing)
        case "unreachable": self = .unreachable
        case "apply_failed": self = .applyFailed
        default: return nil
        }
    }

    static func classify(_ error: any Error) -> GitHubTokenFailure {
        if let failure = error as? GitHubTokenFailure { return failure }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unavailable }
        if rpc.code == -32601 { return .unsupported }
        return GitHubTokenFailure(typed: rpc.data, fallbackCode: rpc.reasonCode) ?? .unavailable
    }
}

public struct GitHubTokenClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status() async throws -> GitHubTokenStatus {
        try await perform("github.token.status", [:])
    }

    public func set(_ token: SecretString) async throws -> GitHubTokenStatus {
        try await perform("github.token.set", ["value": .string(token.reveal())])
    }

    private func perform(_ method: String, _ params: [String: JSONValue]) async throws -> GitHubTokenStatus {
        let result: JSONValue
        do {
            result = try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubTokenFailure.classify(error)
        }
        if let typed = GitHubTokenFailure(typed: result["error"]) { throw typed }
        guard result.objectValue != nil else { throw GitHubTokenFailure.unavailable }
        return GitHubTokenStatus(result)
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

    public enum SetState: Sendable, Equatable {
        case idle
        case submitting
        case saved
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var setState: SetState = .idle
    @ObservationIgnored private let client: GitHubTokenClient
    @ObservationIgnored private var isRefreshing = false

    public init(client: GitHubTokenClient) {
        self.client = client
    }

    public var status: GitHubTokenStatus? {
        if case .ready(let status) = phase { status } else { nil }
    }

    public var headline: String {
        switch phase {
        case .loading: "Checking…"
        case .unsupported: "Not supported yet"
        case .unavailable: "Unknown"
        case .ready(let status): status.headline
        }
    }

    public var footnote: String? {
        switch phase {
        case .unsupported: "This gateway does not support this yet."
        case .unavailable: "Couldn't check the token. Refresh to try again."
        case .loading, .ready: nil
        }
    }

    public var canSet: Bool {
        switch phase {
        case .unsupported, .loading: false
        case .unavailable, .ready: true
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            phase = .ready(try await client.status())
        } catch is CancellationError {
        } catch GitHubTokenFailure.unsupported {
            phase = .unsupported
        } catch {
            if status == nil { phase = .unavailable }
        }
    }

    public func set(_ token: SecretString) async {
        guard setState != .submitting else { return }
        setState = .submitting
        do {
            phase = .ready(try await client.set(token))
            setState = .saved
        } catch is CancellationError {
            setState = .idle
        } catch {
            let failure = GitHubTokenFailure.classify(error)
            if failure == .unsupported { phase = .unsupported }
            setState = .failed(failure.message)
        }
    }

    public func resetSetState() {
        setState = .idle
    }
}
