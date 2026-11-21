import Foundation
import PalREST

public struct SignInOption: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case password
        case browser
    }

    public let id: String
    public let displayName: String
    public let kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public enum SignInDiscovery: Sendable, Equatable {
    case unknown
    case checking
    case ready([SignInOption])
    case unreachable
    case noMethods
}

private struct ProviderEntry: Decodable, Sendable {
    var name: String
    var displayName: String?
    var supportsPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
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
        let options = list.providers.compactMap { provider -> SignInOption? in
            let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let title = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SignInOption(
                id: name,
                displayName: title.isEmpty ? name : title,
                kind: provider.supportsPassword == true ? .password : .browser
            )
        }
        return options.isEmpty ? .noMethods : .ready(options)
    }
}
