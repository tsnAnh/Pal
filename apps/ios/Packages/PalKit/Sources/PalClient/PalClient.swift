import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalREST
import PalTransport

public struct RuntimeDescription: Sendable, Equatable, Decodable {
    public var instanceID: String
    public var profileID: String
    public var authorityEpoch: Int
    public var capabilities: [String]
    public var sessionCreate: SessionCreateDescription?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case profileID = "profile_id"
        case authorityEpoch = "authority_epoch"
        case capabilities
        case sessionCreate = "session_create"
    }

    public var supportsReach: Bool { capabilities.contains(ReachWire.capability) }

    public static let historyPageCapability = "session-history-page-v1"

    public static func supportsHistoryPaging(advertised: JSONValue?) -> Bool {
        guard let advertised, let description = try? advertised.decoded(as: RuntimeDescription.self) else {
            return false
        }
        return description.capabilities.contains(historyPageCapability)
    }

    public static let iosSource = "ios"
    public static let fallbackSource = "gui"

    public var createSource: String {
        sessionCreate?.sources.contains(Self.iosSource) == true ? Self.iosSource : Self.fallbackSource
    }

    public static func createSource(advertised: JSONValue?) -> String {
        guard let advertised, let description = try? advertised.decoded(as: RuntimeDescription.self) else {
            return fallbackSource
        }
        return description.createSource
    }
}

public struct SessionCreateDescription: Sendable, Equatable, Decodable {
    public var sources: [String]
}

public struct SocketTicket: Sendable, Decodable {
    public var ticket: String
    public var ttlSeconds: Int

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }
}

public enum PalClientError: Error, Sendable, Equatable {
    case notSignedIn
    case deviceToolsUnavailable
}

public struct PalClient: Sendable {
    public let auth: AuthSession
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let dialOptions: GatewayDialOptions
    public let presence: ReachPresence?

    public init(
        auth: AuthSession,
        transport: any HTTPTransport,
        diagnostics: Diagnostics = .silent,
        dialOptions: GatewayDialOptions = GatewayDialOptions(),
        presence: ReachPresence? = nil
    ) {
        self.auth = auth
        self.transport = transport
        self.diagnostics = diagnostics
        self.dialOptions = dialOptions
        self.presence = presence
    }

    public func mintSocketTicket(profile: String? = nil) async throws -> SocketTicket {
        let rest = try await restClient()
        var query = [URLQueryItem(name: "socket", value: "gateway")]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        return try await rest.post("/api/webapp/socket-ticket", query: query, as: SocketTicket.self)
    }

    public func connect(profile: String? = nil, reach role: ReachRole = .passive) async throws -> GatewayConnection {
        guard let baseURL = await auth.baseURL else { throw PalClientError.notSignedIn }
        let clock = ContinuousClock()
        let begin = clock.now
        let ticket = try await mintSocketTicket(profile: profile)
        let ticketed = clock.now
        let connection = try await GatewayConnection.dial(
            url: baseURL.webSocketEndpoint("/api/ws"),
            ticket: ticket.ticket,
            options: dialOptions,
            diagnostics: diagnostics
        )
        let dialed = clock.now
        do {
            try await negotiate(connection, role: role)
        } catch {
            await connection.close()
            throw error
        }
        let done = clock.now
        diagnostics.info(
            "launch",
            "gateway connect \(role) ticket=\(Self.milliseconds(ticketed - begin))ms dial=\(Self.milliseconds(dialed - ticketed))ms negotiate=\(Self.milliseconds(done - dialed))ms at +\(LaunchClock.elapsedMilliseconds)ms"
        )
        return connection
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    public func describeRuntime(on connection: GatewayConnection) async throws -> RuntimeDescription {
        if let cached = connection.negotiatedRuntime, let description = try? cached.decoded(as: RuntimeDescription.self) {
            return description
        }
        let result = try await connection.call("runtime.describe", params: [:])
        let description = try result.decoded(as: RuntimeDescription.self)
        connection.recordNegotiatedRuntime(result)
        return description
    }

    private func negotiate(_ connection: GatewayConnection, role: ReachRole) async throws {
        let description: RuntimeDescription
        do {
            description = try await describeRuntime(on: connection)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.info("ws", "runtime.describe unavailable: \(Diagnostics.describe(error))")
            if role == .deviceHost { throw PalClientError.deviceToolsUnavailable }
            return
        }
        guard description.supportsReach, let presence else {
            if role == .deviceHost { throw PalClientError.deviceToolsUnavailable }
            return
        }
        let declared = await presence.declare(on: connection, acceptsOffers: role == .offerTarget, deviceTools: role == .deviceHost)
        if role == .deviceHost, !declared { throw PalClientError.deviceToolsUnavailable }
    }

    private func restClient() async throws -> RESTClient {
        guard let baseURL = await auth.baseURL else { throw PalClientError.notSignedIn }
        return RESTClient(baseURL: baseURL, transport: transport, tokens: auth, diagnostics: diagnostics)
    }
}
