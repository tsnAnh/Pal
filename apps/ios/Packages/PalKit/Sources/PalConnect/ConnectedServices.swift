import Foundation

public enum ServiceKind: String, Sendable, CaseIterable {
    case slack
    case upwork

    public var connectorSlug: String { rawValue }
}

public protocol ServiceSuggestion: Sendable {
    var requiredService: ServiceKind? { get }
}

public struct ConnectedServices: Sendable, Equatable {
    public static let unknown = ConnectedServices(catalog: nil)

    private let connected: Set<String>?

    public init(catalog: ConnectCatalog?) {
        connected = catalog.map { catalog in
            Set(catalog.apps.compactMap { app -> String? in
                guard app.isConnected else { return nil }
                switch app.source {
                case .hosted(let slug): return slug
                case .mcp(let name, _): return name
                case .custom: return nil
                }
            })
        }
    }

    public init(connected services: Set<ServiceKind>) {
        connected = Set(services.map(\.connectorSlug))
    }

    public var isKnown: Bool { connected != nil }

    public func isConnected(_ service: ServiceKind) -> Bool {
        connected?.contains(service.connectorSlug) ?? false
    }

    public func visible<S: ServiceSuggestion>(_ suggestions: [S]) -> [S] {
        suggestions.filter { suggestion in
            suggestion.requiredService.map(isConnected) ?? true
        }
    }
}
