import Foundation
import HermesDiagnostics

public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    func refreshAccessToken(rejecting rejected: String) async throws -> String
}

public enum RESTError: Error, Sendable, Equatable {
    case unauthorized
    case http(status: Int, detail: String?)
    case decoding
    case encoding
}

extension RESTError: DiagnosticSummarizing {
    public var diagnosticSummary: String {
        switch self {
        case .unauthorized: "RESTError.unauthorized"
        case .http(let status, _): "RESTError.http status=\(status)"
        case .decoding: "RESTError.decoding"
        case .encoding: "RESTError.encoding"
        }
    }
}

public struct RESTClient: Sendable {
    public let baseURL: GatewayBaseURL
    private let transport: any HTTPTransport
    private let tokens: (any AccessTokenProvider)?
    private let diagnostics: Diagnostics

    public init(
        baseURL: GatewayBaseURL,
        transport: any HTTPTransport,
        tokens: (any AccessTokenProvider)? = nil,
        diagnostics: Diagnostics = .silent
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    public func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await perform("GET", path, query: query, body: Optional<Data>.none, as: type)
    }

    public func post<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let encoded: Data?
        do {
            encoded = try body.map { try JSONEncoder().encode($0) }
        } catch {
            throw RESTError.encoding
        }
        return try await perform("POST", path, query: query, body: encoded, as: type)
    }

    private func perform<Response: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        as type: Response.Type
    ) async throws -> Response {
        var token = try await tokens?.accessToken()
        var attempt = 0
        while true {
            let result = try await send(method, path, query: query, body: body, bearer: token)
            if result.response.statusCode == 401, let provider = tokens, let rejected = token {
                guard attempt == 0 else { throw RESTError.unauthorized }
                attempt += 1
                diagnostics.info("rest", "401 on \(method) \(path); refreshing credentials")
                token = try await provider.refreshAccessToken(rejecting: rejected)
                continue
            }
            return try decode(result, as: type)
        }
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        bearer: String?
    ) async throws -> HTTPResult {
        var request = URLRequest(url: baseURL.endpoint(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            request.httpBody = Data()
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let started = ContinuousClock.now
        let result = try await transport.send(request)
        let elapsed = ContinuousClock.now - started
        diagnostics.debug("rest", "\(method) \(path) -> \(result.response.statusCode) in \(elapsed.formatted())")
        return result
    }

    private func decode<Response: Decodable & Sendable>(_ result: HTTPResult, as type: Response.Type) throws -> Response {
        guard (200..<300).contains(result.response.statusCode) else {
            if result.response.statusCode == 401 { throw RESTError.unauthorized }
            throw RESTError.http(status: result.response.statusCode, detail: Self.detail(in: result.data))
        }
        do {
            return try JSONDecoder().decode(type, from: result.data)
        } catch {
            throw RESTError.decoding
        }
    }

    private static func detail(in data: Data) -> String? {
        struct Envelope: Decodable { var detail: String? }
        guard let detail = try? JSONDecoder().decode(Envelope.self, from: data).detail else { return nil }
        return String(detail.prefix(200))
    }
}
