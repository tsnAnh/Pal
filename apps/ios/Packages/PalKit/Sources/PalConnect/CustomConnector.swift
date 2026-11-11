import Foundation
import PalProtocol
import PalTransport

public enum CustomConnectorType: String, Sendable, CaseIterable, Hashable {
    case remoteHTTPS
    case remoteSSE

    public static let options: [CustomConnectorType] = [.remoteHTTPS, .remoteSSE]

    public var label: String {
        switch self {
        case .remoteHTTPS: "Remote HTTPS"
        case .remoteSSE: "Remote HTTPS (SSE)"
        }
    }

    public var transport: String {
        switch self {
        case .remoteHTTPS: "http"
        case .remoteSSE: "sse"
        }
    }

    init(wire: String?) {
        self = wire?.lowercased() == "sse" ? .remoteSSE : .remoteHTTPS
    }
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

public struct ConnectorHeader: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public var key: String
    public var value: String
    public let isStored: Bool

    public init(id: UUID = UUID(), key: String = "", value: String = "", isStored: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isStored = isStored
    }

    public var isBlank: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.isEmpty && !isStored
    }

    public var description: String { "ConnectorHeader(key: \(key), stored: \(isStored))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["key": key, "stored": isStored]) }

    public static func withTrailingBlank(_ rows: [ConnectorHeader]) -> [ConnectorHeader] {
        guard let last = rows.last, !last.isBlank else { return rows + [ConnectorHeader()] }
        return rows
    }

    public static func stored(keys: [String]) -> [ConnectorHeader] {
        withTrailingBlank(keys.map { ConnectorHeader(key: $0, isStored: true) })
    }
}

public struct CustomConnectorInfo: Sendable, Hashable {
    public var name: String
    public var url: String
    public var type: CustomConnectorType
    public var headerKeys: [String]
    public var clientID: String?

    public init(name: String, url: String, type: CustomConnectorType = .remoteHTTPS, headerKeys: [String] = [], clientID: String? = nil) {
        self.name = name
        self.url = url
        self.type = type
        self.headerKeys = headerKeys
        self.clientID = clientID
    }
}

public struct McpServerEntry: Decodable, Sendable, Equatable {
    public var name: String
    public var url: String?
    public var transport: String?
    public var enabled: Bool
    public var headers: [String]
    public var clientID: String?

    public init(name: String, url: String? = nil, transport: String? = nil, enabled: Bool = true, headers: [String] = [], clientID: String? = nil) {
        self.name = name
        self.url = url
        self.transport = transport
        self.enabled = enabled
        self.headers = headers
        self.clientID = clientID
    }

    enum CodingKeys: String, CodingKey {
        case name, url, transport, enabled, headers
        case clientID = "client_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        headers = (try? container.decodeIfPresent([String].self, forKey: .headers)) ?? []
        clientID = (try? container.decodeIfPresent(String.self, forKey: .clientID)).flatMap { $0.isEmpty ? nil : $0 }
    }

    var customInfo: CustomConnectorInfo? {
        guard let url, !url.isEmpty else { return nil }
        return CustomConnectorInfo(name: name, url: url, type: CustomConnectorType(wire: transport), headerKeys: headers, clientID: clientID)
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
    case invalidHeader
    case duplicateHeader

    public var message: String {
        switch self {
        case .emptyName: "Give the connector a name."
        case .invalidName: "Use letters, numbers, dashes or underscores in the name."
        case .emptyURL: "Enter the server address."
        case .invalidURL: "That address doesn't look right. Check it and try again."
        case .unsupportedScheme: "The address must start with https://."
        case .insecureURL: "Use a secure https:// address. Plain http is only allowed for servers on your own network."
        case .credentialsInURL: "Remove the username and password from the address. Add them as an HTTP header instead."
        case .invalidHeader: "Check your HTTP headers. Each one needs a valid name and a value."
        case .duplicateHeader: "Each HTTP header name can only be used once."
        }
    }
}

public enum ConnectorURL {
    public static let maxLength = 2048

    public static func normalized(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("://") else { return text }
        let host = URLComponents(string: "https://" + text)?.host ?? ""
        return (PrivateHost.isPrivate(host) ? "http://" : "https://") + text
    }

    public static func validated(_ input: String) throws(CustomConnectorValidationError) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyURL }
        let text = normalized(trimmed)
        guard text.count <= maxLength, let components = URLComponents(string: text) else { throw .invalidURL }
        guard let scheme = components.scheme?.lowercased() else { throw .invalidURL }
        guard scheme == "https" || scheme == "http" else { throw .unsupportedScheme }
        guard let host = components.host, !host.isEmpty else { throw .invalidURL }
        guard components.user == nil, components.password == nil else { throw .credentialsInURL }
        if scheme == "http", !PrivateHost.isPrivate(host) { throw .insecureURL }
        return text
    }
}

public struct CustomConnectorDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var name: String
    public var type: CustomConnectorType
    public var url: String
    public var headers: [ConnectorHeader]
    public var clientID: String
    public var originalHeaderKeys: [String]

    public init(
        name: String = "",
        type: CustomConnectorType = .remoteHTTPS,
        url: String = "",
        headers: [ConnectorHeader] = [],
        clientID: String = "",
        originalHeaderKeys: [String] = []
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.headers = headers
        self.clientID = clientID
        self.originalHeaderKeys = originalHeaderKeys
    }

    public var description: String { "CustomConnectorDraft(name: \(name), type: \(type.rawValue), headers: \(headers.map(\.key)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "type": type.rawValue, "headerKeys": headers.map(\.key)])
    }

    public static let maxNameLength = 48

    public var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do { _ = try ConnectorURL.validated(url) } catch { return false }
        return true
    }

    public var normalizedURL: String? {
        do { return try ConnectorURL.validated(url) } catch { return nil }
    }

    public func validated() throws(CustomConnectorValidationError) -> ValidatedConnector {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw .emptyName }
        guard Self.isSafeKey(trimmedName) else { throw .invalidName }
        let address = try ConnectorURL.validated(url)
        let trimmedClient = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return ValidatedConnector(
            name: trimmedName, url: address, type: type, headers: try Self.validatedHeaders(headers),
            clientID: trimmedClient.isEmpty ? nil : trimmedClient
        )
    }

    static func isSafeKey(_ value: String) -> Bool {
        guard value.count <= maxNameLength, let first = value.unicodeScalars.first, Self.isAlphanumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { Self.isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static let headerSymbols = Set("!#$%&'*+-.^_`|~".unicodeScalars)

    private static func isHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy { isAlphanumeric($0) || headerSymbols.contains($0) }
    }

    private static func isHeaderValue(_ value: String) -> Bool {
        value.count <= 4096 && value.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
    }

    private static func validatedHeaders(_ rows: [ConnectorHeader]) throws(CustomConnectorValidationError) -> [ValidatedHeader] {
        var seen = Set<String>()
        var result: [ValidatedHeader] = []
        for row in rows where !row.isBlank {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isHeaderName(key) else { throw .invalidHeader }
            guard seen.insert(key.lowercased()).inserted else { throw .duplicateHeader }
            if row.value.isEmpty {
                guard row.isStored else { throw .invalidHeader }
                result.append(ValidatedHeader(key: key, value: nil))
            } else {
                guard isHeaderValue(row.value) else { throw .invalidHeader }
                result.append(ValidatedHeader(key: key, value: SecretString(row.value)))
            }
        }
        return result
    }
}

public struct ValidatedHeader: Sendable, Equatable {
    public var key: String
    var value: SecretString?
}

public struct ValidatedConnector: Sendable, Equatable {
    public var name: String
    public var url: String
    public var type: CustomConnectorType
    public var headers: [ValidatedHeader]
    public var clientID: String?
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
        case .authRefused: "The server turned down the sign-in. Check your HTTP headers or sign in again."
        case .noTools: "Connected, but the server doesn't offer any tools yet."
        case .invalidURL: "That address doesn't look right. Check it and try again."
        case .unsupportedTransport: "That connection type isn't supported. Pick Remote HTTPS or Remote HTTPS (SSE)."
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

    static func requiresSignIn(_ result: JSONValue) -> Bool {
        !(result["ok"]?.boolValue ?? false) && (result["oauth_needed"]?.boolValue ?? false)
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
