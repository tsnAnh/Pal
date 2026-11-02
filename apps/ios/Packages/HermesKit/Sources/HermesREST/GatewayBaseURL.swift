import Foundation

public enum GatewayBaseURLError: Error, Sendable, Equatable {
    case empty
    case malformed
    case insecureScheme
    case unsupportedScheme
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
}

public struct GatewayBaseURL: Sendable, Hashable, Codable {
    public let url: URL

    private static let cleartextHosts: Set<String> = ["127.0.0.1", "localhost"]

    public init(validating input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GatewayBaseURLError.empty }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw GatewayBaseURLError.malformed }
        guard scheme == "https" || scheme == "http" else { throw GatewayBaseURLError.unsupportedScheme }
        if scheme == "http", !Self.cleartextHosts.contains(host) { throw GatewayBaseURLError.insecureScheme }
        guard components.user == nil, components.password == nil else { throw GatewayBaseURLError.credentialsNotAllowed }
        guard components.query == nil, components.fragment == nil else { throw GatewayBaseURLError.queryOrFragmentNotAllowed }
        components.scheme = scheme
        components.host = host
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw GatewayBaseURLError.malformed }
        self.url = url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    public var host: String { url.host() ?? "" }

    public var displayString: String { url.absoluteString }

    public func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path += path.hasPrefix("/") ? path : "/" + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    public func webSocketEndpoint(_ path: String) -> URL {
        var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }
}
