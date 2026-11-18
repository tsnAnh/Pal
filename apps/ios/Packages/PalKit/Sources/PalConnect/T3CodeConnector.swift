import Foundation

public enum T3AddressError: Error, Sendable, Equatable {
    case empty
    case invalid
    case unsupportedScheme
    case credentials
    case invalidPort
    case wrongPath
    case insecure

    public var message: String {
        switch self {
        case .empty: "Enter the address T3 Code shows."
        case .invalid: "That address doesn't look right. Use your Mac's Tailscale address, like 100.64.0.5:3773."
        case .unsupportedScheme: "The address must start with http:// or https://, or have no prefix."
        case .credentials: "Remove the username and password from the address."
        case .invalidPort: "The port must be a number from 1 to 65535."
        case .wrongPath: "Leave off everything after the port. Pal adds the rest."
        case .insecure: CustomConnectorValidationError.insecureURL.message
        }
    }

    fileprivate init(_ error: CustomConnectorValidationError) {
        switch error {
        case .emptyURL: self = .empty
        case .unsupportedScheme: self = .unsupportedScheme
        case .insecureURL: self = .insecure
        case .credentialsInURL: self = .credentials
        default: self = .invalid
        }
    }
}

public enum T3Reach: Sendable, Equatable {
    case reachable
    case needsSignIn
    case unreachable
}

public enum T3CodeConnector {
    public static let slug = "t3code"
    public static let name = "T3 Code"
    public static let defaultPort = 3773
    public static let unreachableReason = String(localized: "T3 Code is not reachable")

    public static func mcpURL(fromInput input: String) throws(T3AddressError) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let parts = try split(trimmed)
        let host = parts.host.contains(":") ? "[\(parts.host)]" : parts.host
        let port = parts.port ?? (parts.scheme == "http" ? defaultPort : nil)
        let portSuffix = port.map { ":\($0)" } ?? ""
        let candidate = "\(parts.scheme)://\(host)\(portSuffix)/mcp"
        do { return try ConnectorURL.validated(candidate) } catch { throw T3AddressError(error) }
    }

    private struct Parts {
        var scheme: String
        var host: String
        var port: Int?
    }

    private static func split(_ text: String) throws(T3AddressError) -> Parts {
        var rest = Substring(text)
        var scheme = "http"
        if let marker = rest.range(of: "://") {
            scheme = rest[..<marker.lowerBound].lowercased()
            rest = rest[marker.upperBound...]
        }
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme }
        let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let path = rest[end...]
        guard path.isEmpty || path == "/" || path == "/mcp" else { throw .wrongPath }
        let authority = rest[..<end]
        guard !authority.contains("@") else { throw .credentials }
        let (host, portText) = try hostAndPort(authority)
        var port: Int?
        if let portText { port = try parsePort(portText) }
        return Parts(scheme: scheme, host: String(host), port: port)
    }

    private static func hostAndPort(_ authority: Substring) throws(T3AddressError) -> (Substring, Substring?) {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw .invalid }
            let host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            guard !host.isEmpty else { throw .invalid }
            if after.isEmpty { return (host, nil) }
            guard after.hasPrefix(":") else { throw .invalid }
            return (host, after.dropFirst())
        }
        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = pieces.first, !host.isEmpty, pieces.count <= 2 else { throw .invalid }
        return (host, pieces.count == 2 ? pieces[1] : nil)
    }

    private static func parsePort(_ text: Substring) throws(T3AddressError) -> Int {
        guard text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), (1...65535).contains(value) else {
            throw .invalidPort
        }
        return value
    }
}

extension ConnectApp {
    public func applying(t3Reach reach: T3Reach?) -> ConnectApp {
        guard isT3Code, state == .connected, let reach, reach != .reachable else { return self }
        var updated = self
        updated.state = .needsAuthorization
        updated.authReason = reach == .unreachable ? T3CodeConnector.unreachableReason : ConnectRowState.expiredSignIn
        return updated
    }
}
