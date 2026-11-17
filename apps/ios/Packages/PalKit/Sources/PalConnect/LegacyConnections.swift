import Foundation

public struct LegacyConnectorItem: Decodable, Sendable, Hashable, Identifiable {
    public enum Source: String, Decodable, Sendable {
        case portal
        case composio
        case unknown
    }

    public enum State: String, Decodable, Sendable {
        case needsReconnect = "needs_reconnect"
        case needsSetup = "needs_setup"
        case unmapped
    }

    public var catalogID: String?
    public var name: String
    public var legacySlug: String
    public var source: Source
    public var method: PalCatalogEntry.Method?
    public var state: State
    public var lastSeen: Double?

    public var id: String { legacySlug }

    public init(
        catalogID: String? = nil, name: String, legacySlug: String, source: Source = .portal,
        method: PalCatalogEntry.Method? = nil, state: State = .needsReconnect, lastSeen: Double? = nil
    ) {
        self.catalogID = catalogID
        self.name = name
        self.legacySlug = legacySlug
        self.source = source
        self.method = method
        self.state = state
        self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey {
        case name, method, state, source = "legacy_source"
        case catalogID = "catalog_id"
        case legacySlug = "legacy_slug"
        case lastSeen = "last_seen"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalogID = try container.decodeIfPresent(String.self, forKey: .catalogID)
        name = try container.decode(String.self, forKey: .name)
        legacySlug = try container.decode(String.self, forKey: .legacySlug)
        source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? .unknown
        method = try? container.decodeIfPresent(PalCatalogEntry.Method.self, forKey: .method)
        state = (try? container.decodeIfPresent(State.self, forKey: .state)) ?? .unmapped
        lastSeen = try container.decodeIfPresent(Double.self, forKey: .lastSeen)
    }
}

public struct LegacyConnectionsResult: Decodable, Sendable, Equatable {
    public var sourceReadable: Bool
    public var items: [LegacyConnectorItem]

    public init(sourceReadable: Bool, items: [LegacyConnectorItem] = []) {
        self.sourceReadable = sourceReadable
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case items
        case sourceReadable = "source_readable"
    }

    public var isUnreadable: Bool { !sourceReadable && items.isEmpty }
}

public enum LegacyReconnectRoute: Sendable, Equatable {
    case connect(appID: String)
    case signIn(appID: String)
    case needsSetup
    case noDirectOption

    public var actionTitle: String? {
        switch self {
        case .connect, .signIn: String(localized: "Reconnect")
        case .needsSetup, .noDirectOption: nil
        }
    }

    public var appID: String? {
        switch self {
        case .connect(let id), .signIn(let id): id
        case .needsSetup, .noDirectOption: nil
        }
    }
}

public struct LegacyReconnectRow: Identifiable, Sendable, Equatable {
    public var item: LegacyConnectorItem
    public var route: LegacyReconnectRoute

    public var id: String { item.legacySlug }
    public var summary: String { LegacyReconnectText.summary(source: item.source, route: route) }
}

public enum LegacyReconnectText {
    public static func summary(source: LegacyConnectorItem.Source, route: LegacyReconnectRoute) -> String {
        let origin = switch source {
        case .portal: String(localized: "You connected this through Nous Portal.")
        case .composio: String(localized: "You connected this through Composio.")
        case .unknown: String(localized: "You connected this earlier.")
        }
        let next = switch route {
        case .connect, .signIn: String(localized: "Reconnect it once to keep using it.")
        case .needsSetup: String(localized: "Needs setup on your Pal before it can connect.")
        case .noDirectOption: String(localized: "No direct option yet.")
        }
        return "\(origin) \(next)"
    }
}

public enum LegacyReconnect {
    private enum Handling {
        case catalogConnect
        case needsSetup
        case nativeSignIn
    }

    private static let handling: [PalCatalogEntry.Method: Handling] = [
        .none: .catalogConnect,
        .mcpOAuth: .catalogConnect,
        .apiKey: .catalogConnect,
        .oauthClient: .needsSetup,
        .native: .nativeSignIn,
    ]

    public static func rows(_ result: LegacyConnectionsResult, catalog: ConnectCatalog, dismissed: Set<String>) -> [LegacyReconnectRow] {
        result.items.compactMap { item in
            guard !dismissed.contains(item.legacySlug) else { return nil }
            if let app = app(for: item, in: catalog), app.state == .connected { return nil }
            return LegacyReconnectRow(item: item, route: route(for: item, in: catalog))
        }
    }

    public static func route(for item: LegacyConnectorItem, in catalog: ConnectCatalog) -> LegacyReconnectRoute {
        guard item.state != .unmapped, let method = item.method, let kind = handling[method] else { return .noDirectOption }
        switch kind {
        case .needsSetup: return .needsSetup
        case .catalogConnect: return app(for: item, in: catalog).map { .connect(appID: $0.id) } ?? .noDirectOption
        case .nativeSignIn: return app(for: item, in: catalog).map { .signIn(appID: $0.id) } ?? .noDirectOption
        }
    }

    private static func app(for item: LegacyConnectorItem, in catalog: ConnectCatalog) -> ConnectApp? {
        guard let slug = item.catalogID else { return nil }
        let ids = slug == ServiceKind.google.connectorSlug
            ? [GoogleWorkspaceCatalog.appID] : ["connector:\(slug)", "mcp:\(slug)"]
        return catalog.apps.first { ids.contains($0.id) }
    }
}

public protocol LegacyDismissals: Sendable {
    func dismissed(profile: String?) -> Set<String>
    func dismiss(_ legacySlug: String, profile: String?)
}

public struct UserDefaultsLegacyDismissals: LegacyDismissals, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ profile: String?) -> String {
        "pal.legacyConnections.dismissed.\(profile ?? "default")"
    }

    public func dismissed(profile: String?) -> Set<String> {
        Set(defaults.stringArray(forKey: key(profile)) ?? [])
    }

    public func dismiss(_ legacySlug: String, profile: String?) {
        var held = dismissed(profile: profile)
        held.insert(legacySlug)
        defaults.set(held.sorted(), forKey: key(profile))
    }
}
