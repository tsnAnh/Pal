import Foundation
import PalREST

public struct SignInOption: Sendable, Equatable, Identifiable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public enum SignInDiscovery: Sendable, Equatable {
    case unknown
    case checking
    case ready(SignInOption)
    case unreachable
    case noMethods
}

private struct ProviderEntry: Decodable, Sendable {
    var name: String
    var supportsPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case supportsPassword = "supports_password"
    }
}

private struct ProviderList: Decodable, Sendable {
    var providers: [ProviderEntry]
}

extension NativeSignIn {

    public func discoverOptions(baseURL: GatewayBaseURL) async -> SignInDiscovery {
        let client = RESTClient(baseURL: baseURL, transport: transport, diagnostics: diagnostics)
        guard let list = try? await client.get("/api/auth/providers", as: ProviderList.self) else { return .unreachable }
        let account = list.providers.lazy
            .filter { $0.supportsPassword == true }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return account.map { .ready(SignInOption(id: $0)) } ?? .noMethods
    }
}
