import Foundation
import HermesAuth
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport

public struct RuntimeDescription: Sendable, Equatable, Decodable {
    public var instanceID: String
    public var profileID: String
    public var authorityEpoch: Int
    public var capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case profileID = "profile_id"
        case authorityEpoch = "authority_epoch"
        case capabilities
    }
}

public struct SocketTicket: Sendable, Decodable {
    public var ticket: String
    public var ttlSeconds: Int

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }
}

public enum HermesClientError: Error, Sendable, Equatable {
    case notSignedIn
}

public struct HermesClient: Sendable {
    public let auth: AuthSession
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let dialOptions: GatewayDialOptions

    public init(
        auth: AuthSession,
        transport: any HTTPTransport,
        diagnostics: Diagnostics = .silent,
        dialOptions: GatewayDialOptions = GatewayDialOptions()
    ) {
        self.auth = auth
        self.transport = transport
        self.diagnostics = diagnostics
        self.dialOptions = dialOptions
    }

    public func mintSocketTicket(profile: String? = nil) async throws -> SocketTicket {
        let rest = try await restClient()
        var query = [URLQueryItem(name: "socket", value: "gateway")]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        return try await rest.post("/api/webapp/socket-ticket", query: query, as: SocketTicket.self)
    }

    public func connect(profile: String? = nil) async throws -> GatewayConnection {
        guard let baseURL = await auth.baseURL else { throw HermesClientError.notSignedIn }
        let ticket = try await mintSocketTicket(profile: profile)
        return try await GatewayConnection.dial(
            url: baseURL.webSocketEndpoint("/api/ws"),
            ticket: ticket.ticket,
            options: dialOptions,
            diagnostics: diagnostics
        )
    }

    public func describeRuntime(on connection: GatewayConnection) async throws -> RuntimeDescription {
        try await connection.call("runtime.describe", params: [:]).decoded(as: RuntimeDescription.self)
    }

    private func restClient() async throws -> RESTClient {
        guard let baseURL = await auth.baseURL else { throw HermesClientError.notSignedIn }
        return RESTClient(baseURL: baseURL, transport: transport, tokens: auth, diagnostics: diagnostics)
    }
}
