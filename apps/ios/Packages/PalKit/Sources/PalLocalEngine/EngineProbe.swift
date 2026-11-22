import Foundation
import PalAuth
import PalREST

public enum EngineProbeResult: Sendable, Equatable {
    case unreachable
    case running
    case ready
}

public protocol EngineProbing: Sendable {
    func probe(port: Int, token: LocalToken?) async -> EngineProbeResult
}

public struct HTTPEngineProbe: EngineProbing {
    public static let statusPath = "/api/status"
    public static let authenticatedPath = "/api/profiles"

    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(transport: any HTTPTransport, timeout: TimeInterval = 3) {
        self.transport = transport
        self.timeout = timeout
    }

    public func probe(port: Int, token: LocalToken?) async -> EngineProbeResult {
        guard let baseURL = try? LocalEngineCredential.baseURL(port: port) else { return .unreachable }
        guard let status = await get(baseURL.endpoint(Self.statusPath), bearer: nil), (200..<300).contains(status) else {
            return .unreachable
        }
        guard let token else { return .running }
        let accepted = await get(baseURL.endpoint(Self.authenticatedPath), bearer: token)
        return accepted.map { (200..<300).contains($0) } == true ? .ready : .running
    }

    private func get(_ url: URL, bearer: LocalToken?) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer.reveal())", forHTTPHeaderField: "Authorization") }
        return try? await transport.send(request).response.statusCode
    }
}
