import Foundation
import PalProtocol

public struct HostedConnectorEntry: Decodable, Sendable, Equatable {
    public var slug: String
    public var name: String
    public var description: String
    public var category: String
    public var logoURL: URL?

    public init(slug: String, name: String, description: String, category: String, logoURL: URL? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.category = category
        self.logoURL = logoURL
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, description, category
        case logoURL = "logo_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        logoURL = (try container.decodeIfPresent(String.self, forKey: .logoURL)).flatMap { URL(string: $0) }.flatMap(Self.secure)
    }

    private static func secure(_ url: URL) -> URL? {
        url.scheme?.lowercased() == "https" ? url : nil
    }
}

public struct HostedConnectorState: Decodable, Sendable, Equatable {
    public var connector: String
    public var connected: Bool
    public var connectionStatus: String?

    public init(connector: String, connected: Bool, connectionStatus: String? = nil) {
        self.connector = connector
        self.connected = connected
        self.connectionStatus = connectionStatus
    }

    enum CodingKeys: String, CodingKey {
        case connector, connected
        case connectionStatus = "connection_status"
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
}

public enum ConnectAppSource: Sendable, Hashable {
    case hosted(slug: String)
    case mcp(name: String, requires: [String])
    case custom(CustomConnectorInfo)
}

public struct ConnectApp: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: String
    public var iconURL: URL?
    public var source: ConnectAppSource
    public var state: ConnectAppState
    public var authReason: String?
    public var setup: String

    public init(id: String, name: String, summary: String, category: String, iconURL: URL?, source: ConnectAppSource, state: ConnectAppState, authReason: String? = nil, setup: String = "") {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.iconURL = iconURL
        self.source = source
        self.state = state
        self.authReason = authReason
        self.setup = setup
    }

    public var isConnected: Bool { state == .connected }
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
        "Communication", "Work management", "Files and docs", "Design and media", "Developer",
        "Data and monitoring", "Sales and support", "Commerce",
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
        apps.filter { $0.state != .disconnected }
    }

    public func matching(_ query: String) -> [ConnectApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedStandardContains(needle) || $0.summary.localizedStandardContains(needle) }
    }

    public static func make(hosted: [HostedConnectorEntry], states: [HostedConnectorState], mcp: [McpPresetEntry], skills: [InstalledSkill] = [], servers: [McpServerEntry] = []) -> ConnectCatalog {
        let stateBySlug = Dictionary(states.map { ($0.connector, $0) }, uniquingKeysWith: { _, last in last })
        let hostedSlugs = Set(hosted.map(\.slug))
        var apps = hosted.map { entry in
            ConnectApp(
                id: "connector:\(entry.slug)", name: entry.name, summary: entry.description,
                category: entry.category.isEmpty ? otherCategory : entry.category, iconURL: entry.logoURL,
                source: .hosted(slug: entry.slug), state: hostedState(stateBySlug[entry.slug])
            )
        }
        let standalone = mcp.filter { preset in preset.connectorSlug.map { !hostedSlugs.contains($0) } ?? true }
        apps += standalone.map { preset in
            ConnectApp(
                id: "mcp:\(preset.name)", name: displayName(preset.name), summary: preset.description, category: otherCategory,
                iconURL: nil, source: .mcp(name: preset.name, requires: preset.requires),
                state: mcpState(preset), authReason: preset.needsAuthReason, setup: preset.setup
            )
        }
        let presetNames = Set(mcp.map(\.name))
        apps += servers.filter { !presetNames.contains($0.name) }.compactMap { entry in
            entry.customInfo.map { info in
                ConnectApp(
                    id: "custom:\(info.name)", name: info.name, summary: "Custom connector", category: customCategory,
                    iconURL: nil, source: .custom(info), state: entry.enabled ? .connected : .disconnected
                )
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ConnectCatalog(apps: apps, skills: skills)
    }

    static func mcpState(_ preset: McpPresetEntry) -> ConnectAppState {
        guard preset.installed && preset.enabled else { return .disconnected }
        let reason = preset.needsAuthReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? .connected : .needsAuthorization
    }

    static func hostedState(_ state: HostedConnectorState?) -> ConnectAppState {
        guard let state, state.connected else { return .disconnected }
        switch state.connectionStatus {
        case nil, "active": return .connected
        case "pending", "failed", "expired": return .needsAuthorization
        default: return .disconnected
        }
    }

    static func displayName(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
