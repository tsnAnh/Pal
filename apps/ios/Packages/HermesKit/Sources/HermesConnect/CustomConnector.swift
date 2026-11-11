import Foundation
import HermesProtocol
import HermesTransport

public enum CustomConnectorTransport: String, Sendable, CaseIterable, Hashable {
    case http
    case sse

    init(wire: String?) {
        self = wire?.lowercased() == "sse" ? .sse : .http
    }
}

public enum CustomConnectorAuth: String, Sendable, CaseIterable, Hashable {
    case none
    case bearer
    case oauth

    init(wire: String?) {
        switch wire?.lowercased() {
        case "header", "bearer": self = .bearer
        case "oauth": self = .oauth
        default: self = .none
        }
    }
}

public struct ConnectorSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isEmpty: Bool { value.isEmpty }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public struct ConnectorTool: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String

    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct CustomConnectorInfo: Sendable, Hashable {
    public var name: String
    public var url: String
    public var transport: CustomConnectorTransport
    public var auth: CustomConnectorAuth

    public init(name: String, url: String, transport: CustomConnectorTransport = .http, auth: CustomConnectorAuth = .none) {
        self.name = name
        self.url = url
        self.transport = transport
        self.auth = auth
    }
}

public struct McpServerEntry: Decodable, Sendable, Equatable {
    public var name: String
    public var url: String?
    public var transport: String?
    public var auth: String?
    public var enabled: Bool

    public init(name: String, url: String? = nil, transport: String? = nil, auth: String? = nil, enabled: Bool = true) {
        self.name = name
        self.url = url
        self.transport = transport
        self.auth = auth
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case name, url, transport, auth, enabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        auth = try container.decodeIfPresent(String.self, forKey: .auth)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var customInfo: CustomConnectorInfo? {
        guard let url, !url.isEmpty else { return nil }
        return CustomConnectorInfo(name: name, url: url, transport: CustomConnectorTransport(wire: transport), auth: CustomConnectorAuth(wire: auth))
    }
}

public enum CustomConnectorValidationError: Error, Sendable, Equatable {
    case emptyName
    case invalidName
    case emptyURL
    case invalidURL
    case unsupportedScheme
    case insecureURL
    case credentialsInURL
    case tokenRequired

    public var message: String {
        switch self {
        case .emptyName: "Give the connector a name."
        case .invalidName: "Use letters, numbers, dashes or underscores in the name."
        case .emptyURL: "Enter the server address."
        case .invalidURL: "That address doesn't look right. Check it and try again."
        case .unsupportedScheme: "The address must start with https://."
        case .insecureURL: "Use a secure https:// address. Plain http is only allowed for servers on your own network."
        case .credentialsInURL: "Remove the username and password from the address. Use a token instead."
        case .tokenRequired: "Enter the token this server expects."
        }
    }
}

public struct CustomConnectorDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var name: String
    public var url: String
    public var transport: CustomConnectorTransport
    public var auth: CustomConnectorAuth
    public var bearerToken: ConnectorSecret?
    public var originalAuth: CustomConnectorAuth?

    public init(
        name: String = "",
        url: String = "",
        transport: CustomConnectorTransport = .http,
        auth: CustomConnectorAuth = .none,
        bearerToken: ConnectorSecret? = nil,
        originalAuth: CustomConnectorAuth? = nil
    ) {
        self.name = name
        self.url = url
        self.transport = transport
        self.auth = auth
        self.bearerToken = bearerToken
        self.originalAuth = originalAuth
    }

    public var description: String { "CustomConnectorDraft(name: \(name), transport: \(transport.rawValue), auth: \(auth.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "transport": transport.rawValue, "auth": auth.rawValue])
    }

    public static let maxNameLength = 48
    public static let maxURLLength = 2048

    public func validated() throws(CustomConnectorValidationError) -> ValidatedConnector {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw .emptyName }
        guard Self.isSafeKey(trimmedName) else { throw .invalidName }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw .emptyURL }
        try Self.validateURL(trimmedURL)
        let token = bearerToken.flatMap { $0.isEmpty ? nil : $0 }
        if auth == .bearer, token == nil, originalAuth != .bearer { throw .tokenRequired }
        return ValidatedConnector(name: trimmedName, url: trimmedURL, transport: transport, auth: auth, token: auth == .bearer ? token : nil)
    }

    static func isSafeKey(_ value: String) -> Bool {
        guard value.count <= maxNameLength, let first = value.unicodeScalars.first, Self.isAlphanumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { Self.isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func validateURL(_ text: String) throws(CustomConnectorValidationError) {
        guard text.count <= maxURLLength, let components = URLComponents(string: text) else { throw .invalidURL }
        guard let scheme = components.scheme?.lowercased() else { throw .invalidURL }
        guard scheme == "https" || scheme == "http" else { throw .unsupportedScheme }
        guard let host = components.host, !host.isEmpty else { throw .invalidURL }
        guard components.user == nil, components.password == nil else { throw .credentialsInURL }
        if scheme == "http", !PrivateHost.isPrivate(host) { throw .insecureURL }
    }
}

public struct ValidatedConnector: Sendable, Equatable {
    public var name: String
    public var url: String
    public var transport: CustomConnectorTransport
    public var auth: CustomConnectorAuth
    var token: ConnectorSecret?
}

enum PrivateHost {
    static func isPrivate(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        guard let octets = ipv4(host) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }
}

public enum ConnectorFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case unreachable
    case authRefused
    case noTools
    case invalidURL
    case unsupportedTransport
    case serverError
    case nameTaken
    case offline
    case signInCancelled
    case validation(CustomConnectorValidationError)

    public var message: String {
        switch self {
        case .unreachable: "Couldn't reach that server. Check the address and that it's online."
        case .authRefused: "The server turned down the sign-in. Check your token or sign in again."
        case .noTools: "Connected, but the server doesn't offer any tools yet."
        case .invalidURL: "That address doesn't look right. Check it and try again."
        case .unsupportedTransport: "That connection type isn't supported. Pick Streamable HTTP or SSE."
        case .serverError: "The server ran into a problem. Try again in a moment."
        case .nameTaken: "You already have a connector with that name. Pick another name."
        case .offline: "Couldn't reach your Hermes. Check your connection and try again."
        case .signInCancelled: "Sign-in was cancelled."
        case .validation(let error): error.message
        }
    }

    public var description: String { message }
}

extension ConnectorFailure {
    static func from(_ error: any Error) -> ConnectorFailure {
        if let failure = error as? ConnectorFailure { return failure }
        if let validation = error as? CustomConnectorValidationError { return .validation(validation) }
        if let transport = error as? GatewayTransportError {
            switch transport {
            case .rpc(let rpc): return from(rpc)
            case .timedOut, .closed, .handshakeRejected, .subprotocolNotNegotiated: return .offline
            case .unexpectedFirstFrame, .encoding: return .serverError
            }
        }
        return .serverError
    }

    static func from(_ error: RPCError) -> ConnectorFailure {
        switch error.code {
        case 4063:
            let hint = [error.reasonCode, error.data?["reason"]?.stringValue, error.message].compactMap { $0?.lowercased() }.joined(separator: " ")
            return hint.contains("transport") ? .unsupportedTransport : .invalidURL
        case 4090: return .nameTaken
        default: return .serverError
        }
    }

    static func evaluate(testResult result: JSONValue) -> ConnectorFailure? {
        let ok = result["ok"]?.boolValue ?? false
        if ok {
            let tools = result["tools"]?.arrayValue ?? []
            return tools.isEmpty ? .noTools : nil
        }
        if let reason = result["reason"]?.stringValue?.lowercased() {
            switch reason {
            case "unreachable": return .unreachable
            case "auth_refused": return .authRefused
            case "server_error": return .serverError
            default: break
            }
        }
        let oauthNeeded = result["oauth_needed"]?.boolValue ?? false
        let hasTokens = result["oauth_tokens_present"]?.boolValue ?? false
        if oauthNeeded, !hasTokens { return .authRefused }
        return classify(message: result["error"]?.stringValue ?? "")
    }

    private static func classify(message: String) -> ConnectorFailure {
        let text = message.lowercased()
        let auth = ["401", "403", "unauthorized", "unauthorised", "forbidden", "authenticat", "invalid token", "invalid_token"]
        if auth.contains(where: { text.contains($0) }) { return .authRefused }
        let network = ["timeout", "timed out", "refused", "unreachable", "resolve", "dns", "connect", "no route", "network"]
        if network.contains(where: { text.contains($0) }) { return .unreachable }
        return .serverError
    }

    static func tools(from result: JSONValue) -> [ConnectorTool] {
        (result["tools"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            return ConnectorTool(name: name, description: entry["description"]?.stringValue ?? "")
        }
    }
}

public enum CustomConnectorPhase: Sendable, Equatable {
    case idle
    case validating
    case saving
    case connecting
    case connected([ConnectorTool])
    case failed(ConnectorFailure)

    public var isInFlight: Bool {
        switch self {
        case .validating, .saving, .connecting: true
        case .idle, .connected, .failed: false
        }
    }
}

public enum CustomConnectorEvent: Sendable, Equatable {
    case submit
    case validated
    case saved
    case connected([ConnectorTool])
    case failed(ConnectorFailure)
    case reset
}

public struct CustomConnectorMachine: Sendable, Equatable {
    public private(set) var phase: CustomConnectorPhase

    public init(phase: CustomConnectorPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func send(_ event: CustomConnectorEvent) -> Bool {
        switch (phase, event) {
        case (.idle, .submit), (.failed, .submit), (.connected, .submit):
            phase = .validating
        case (.validating, .validated):
            phase = .saving
        case (.saving, .saved):
            phase = .connecting
        case (.connecting, .connected(let tools)):
            phase = .connected(tools)
        case (.validating, .failed(let failure)), (.saving, .failed(let failure)), (.connecting, .failed(let failure)):
            phase = .failed(failure)
        case (.idle, .reset), (.failed, .reset), (.connected, .reset):
            phase = .idle
        default:
            return false
        }
        return true
    }
}
