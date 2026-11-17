import Foundation
import PalProtocol

public struct PalCatalogEntry: Decodable, Sendable, Hashable {
    public enum Method: Decodable, Sendable, Hashable {
        case mcpOAuth
        case none
        case apiKey
        case native
        case oauthClient
        case unsupported(String)

        private static let known: [String: Method] = [
            "mcp_oauth": .mcpOAuth, "none": .none, "api_key": .apiKey, "native": .native, "oauth_client": .oauthClient,
        ]

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self.known[raw] ?? .unsupported(raw)
        }

        public var isSupported: Bool {
            if case .unsupported = self { false } else { true }
        }
    }

    public enum Status: String, Decodable, Sendable {
        case connected
        case needsReconnect = "needs_reconnect"
        case notConnected = "not_connected"
        case needsSetup = "needs_setup"
    }

    public var slug: String
    public var name: String
    public var category: String
    public var icon: String
    public var method: Method
    public var verified: Bool
    public var mcpURL: URL?
    public var status: Status
    public var notes: String?

    public init(
        slug: String, name: String, category: String = "", icon: String = "", method: Method,
        verified: Bool = false, mcpURL: URL? = nil, status: Status = .notConnected, notes: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.category = category
        self.icon = icon
        self.method = method
        self.verified = verified
        self.mcpURL = mcpURL
        self.status = status
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, category, icon, method, verified, status, notes
        case mcpURL = "mcp_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
        method = try container.decode(Method.self, forKey: .method)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        status = try container.decode(Status.self, forKey: .status)
        notes = ConnectorCardState.cleaned(try container.decodeIfPresent(String.self, forKey: .notes))
        mcpURL = (try container.decodeIfPresent(String.self, forKey: .mcpURL)).flatMap { URL(string: $0) }.flatMap(Self.secure)
    }

    private static func secure(_ url: URL) -> URL? {
        url.scheme?.lowercased() == "https" ? url : nil
    }

    var hasGuidedSetup: Bool {
        method == .oauthClient && OAuthClientGuide.guidedSlugs.contains(slug)
    }

    var appState: ConnectAppState {
        guard method.isSupported else { return .needsSetup }
        switch status {
        case .connected: .connected
        case .needsReconnect: .needsAuthorization
        case .needsSetup: .needsSetup
        case .notConnected: .disconnected
        }
    }
}

public struct McpPresetEntry: Decodable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var connectorSlug: String?
    public var installed: Bool
    public var enabled: Bool
    public var requires: [String]
    public var needsAuthReason: String?
    public var setup: String

    public init(name: String, description: String, connectorSlug: String? = nil, installed: Bool = false, enabled: Bool = false, requires: [String] = [], needsAuthReason: String? = nil, setup: String = "") {
        self.name = name
        self.description = description
        self.connectorSlug = connectorSlug
        self.installed = installed
        self.enabled = enabled
        self.requires = requires
        self.needsAuthReason = needsAuthReason
        self.setup = setup
    }

    enum CodingKeys: String, CodingKey {
        case name, description, installed, enabled, requires, setup
        case connectorSlug = "connector_slug"
        case needsAuthReason = "needs_auth_reason"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        connectorSlug = try container.decodeIfPresent(String.self, forKey: .connectorSlug)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
        setup = try container.decodeIfPresent(String.self, forKey: .setup) ?? ""
    }
}

public enum ConnectAppState: Sendable, Equatable {
    case disconnected
    case connected
    case needsAuthorization
    case needsSetup
}

public enum ConnectAppSource: Sendable, Hashable {
    case catalog(PalCatalogEntry)
    case mcp(name: String, requires: [String])
    case custom(CustomConnectorInfo)
    case googleWorkspace
}

public struct ConnectApp: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: String
    public var source: ConnectAppSource
    public var state: ConnectAppState
    public var authReason: String?
    public var setup: String

    public init(
        id: String, name: String, summary: String, category: String, source: ConnectAppSource, state: ConnectAppState,
        authReason: String? = nil, setup: String = ""
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.source = source
        self.state = state
        self.authReason = authReason
        self.setup = setup
    }

    public var isConnected: Bool { state == .connected }

    public var requiresToken: Bool {
        switch source {
        case .mcp(_, let requires): !requires.isEmpty
        case .catalog(let entry): entry.method == .apiKey
        case .custom, .googleWorkspace: false
        }
    }
}

public struct InstalledSkill: Sendable, Equatable, Identifiable {
    public var name: String
    public var category: String

    public var id: String { "\(category)/\(name)" }

    public init(name: String, category: String) {
        self.name = name
        self.category = category
    }

    public static func parse(_ value: JSONValue) -> [InstalledSkill] {
        guard let groups = value["skills"]?.objectValue else { return [] }
        return groups.flatMap { category, names in
            (names.arrayValue ?? []).compactMap { $0.stringValue }.map { InstalledSkill(name: $0, category: category) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct ConnectCatalog: Sendable, Equatable {
    public static let otherCategory = "Other"
    public static let customCategory = "Custom"
    private static let preferredOrder = [
        "Developer tools", "Hosting and infrastructure", "Monitoring and analytics", "Work management", "Docs and files",
        "Design and web", "Sales and support", "Finance", "Communication",
    ]

    public var apps: [ConnectApp]
    public var skills: [InstalledSkill]

    public init(apps: [ConnectApp] = [], skills: [InstalledSkill] = []) {
        self.apps = apps
        self.skills = skills
    }

    public func matchingSkills(_ query: String) -> [InstalledSkill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return skills.filter { $0.name.localizedStandardContains(needle) || $0.category.localizedStandardContains(needle) }
    }

    public var categories: [String] {
        let present = Set(apps.map(\.category))
        let preferred = Self.preferredOrder.filter(present.contains)
        let rest = present.subtracting(preferred).subtracting([Self.otherCategory]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return preferred + rest + (present.contains(Self.otherCategory) ? [Self.otherCategory] : [])
    }

    public func apps(in category: String) -> [ConnectApp] {
        apps.filter { $0.category == category }
    }

    public var connectedApps: [ConnectApp] {
        apps.filter { $0.state == .connected || $0.state == .needsAuthorization }
    }

    public func matching(_ query: String) -> [ConnectApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedStandardContains(needle) || $0.summary.localizedStandardContains(needle) }
    }

    public static func make(
        catalog: [PalCatalogEntry], mcp: [McpPresetEntry], skills: [InstalledSkill] = [],
        servers: [McpServerEntry] = [], google: GoogleWorkspaceStatus? = nil
    ) -> ConnectCatalog {
        let catalogSlugs = Set(catalog.map(\.slug))
        var apps = catalog.filter { $0.method != .native }.map { entry in
            ConnectApp(
                id: "connector:\(entry.slug)", name: entry.name, summary: summary(for: entry),
                category: entry.category.isEmpty ? otherCategory : entry.category,
                source: .catalog(entry), state: entry.appState
            )
        }
        let presetNames = Set(mcp.map(\.name))
        apps += servers.filter { !presetNames.contains($0.name) && !catalogSlugs.contains($0.name) }.compactMap { entry in
            entry.customInfo.map { info in
                ConnectApp(
                    id: "custom:\(info.name)", name: info.name, summary: "Custom connector", category: customCategory,
                    source: .custom(info), state: entry.enabled ? .connected : .disconnected
                )
            }
        }
        if let google {
            apps.append(
                ConnectApp(
                    id: GoogleWorkspaceCatalog.appID, name: GoogleWorkspaceCatalog.name, summary: GoogleWorkspaceCatalog.summary,
                    category: "Docs and files", source: .googleWorkspace, state: google.catalogState,
                    authReason: google.state == .reauthNeeded ? (google.reauthReason ?? .unknown).plainReason : nil
                )
            )
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ConnectCatalog(apps: apps, skills: skills)
    }

    static func summary(for entry: PalCatalogEntry) -> String {
        let setup = setupSummary(for: entry)
        if !setup.isEmpty || entry.verified { return setup }
        return String(localized: "Not verified: may not connect")
    }

    private static func setupSummary(for entry: PalCatalogEntry) -> String {
        if !entry.method.isSupported { return String(localized: "Needs a newer Pal") }
        if entry.hasGuidedSetup {
            if let notes = entry.notes { return notes }
            return entry.status == .needsSetup ? String(localized: "Save your OAuth client once to connect.") : ""
        }
        return entry.status == .needsSetup ? String(localized: "Needs setup on your Pal before it can connect.") : ""
    }
}
