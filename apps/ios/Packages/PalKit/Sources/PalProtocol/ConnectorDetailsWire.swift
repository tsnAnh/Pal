import Foundation

public enum ConnectorToolGroup: String, Sendable, Hashable, CaseIterable {
    case read
    case write
    case never
    case tool

    public var modes: [ConnectorPolicyMode] {
        switch self {
        case .read: [.auto, .ask, .off]
        case .write: [.ask, .off]
        case .tool: [.on, .off]
        case .never: []
        }
    }

    public var fallbackMode: ConnectorPolicyMode? {
        switch self {
        case .read, .write: .ask
        case .tool: .on
        case .never: nil
        }
    }
}

public enum ConnectorPolicyMode: String, Sendable, Hashable {
    case auto
    case ask
    case off
    case on
}

public struct ConnectorDetailTool: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String
    public var description: String
    public var group: ConnectorToolGroup

    public var id: String { name }

    public init(name: String, title: String, description: String, group: ConnectorToolGroup) {
        self.name = name
        self.title = title
        self.description = description
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case name, title, description, group
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "tool name") }
        guard let group = ConnectorToolGroup(rawValue: try container.decode(String.self, forKey: .group)) else {
            throw DecodingError.dataCorruptedError(forKey: .group, in: container, debugDescription: "tool group")
        }
        let title = (try? container.decodeIfPresent(String.self, forKey: .title))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name
        self.title = title.isEmpty ? name : title
        self.description = (try? container.decodeIfPresent(String.self, forKey: .description))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.group = group
    }
}

public struct ConnectorSkill: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String
    public var description: String

    public var id: String { name }

    public init(name: String, title: String, description: String) {
        self.name = name
        self.title = title
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name, title, description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "skill name") }
        let title = (try? container.decodeIfPresent(String.self, forKey: .title))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name
        self.title = title.isEmpty ? name : title
        self.description = (try? container.decodeIfPresent(String.self, forKey: .description))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct ConnectorPolicy: Decodable, Sendable, Hashable {
    private var modes: [ConnectorToolGroup: ConnectorPolicyMode]

    public init(_ modes: [ConnectorToolGroup: ConnectorPolicyMode] = [:]) {
        self.modes = modes.filter { $0.key.modes.contains($0.value) }
    }

    enum CodingKeys: String, CodingKey {
        case read, write, tool
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var found: [ConnectorToolGroup: ConnectorPolicyMode] = [:]
        for (key, group) in [(CodingKeys.read, ConnectorToolGroup.read), (.write, .write), (.tool, .tool)] {
            if let raw = try? container.decodeIfPresent(String.self, forKey: key), let mode = ConnectorPolicyMode(rawValue: raw) { found[group] = mode }
        }
        self.init(found)
    }

    public func mode(for group: ConnectorToolGroup) -> ConnectorPolicyMode? {
        modes[group] ?? group.fallbackMode
    }
}

public struct ConnectorDetails: Decodable, Sendable, Hashable {
    public var slug: String
    public var grouped: Bool
    public var toolsKnown: Bool
    public var tools: [ConnectorDetailTool]
    public var policy: ConnectorPolicy
    public var skills: [ConnectorSkill]

    public init(
        slug: String, grouped: Bool = false, toolsKnown: Bool = false, tools: [ConnectorDetailTool] = [], policy: ConnectorPolicy = ConnectorPolicy(),
        skills: [ConnectorSkill] = []
    ) {
        self.slug = slug
        self.grouped = grouped
        self.toolsKnown = toolsKnown
        self.tools = tools
        self.policy = policy
        self.skills = skills
    }

    enum CodingKeys: String, CodingKey {
        case slug, grouped, tools, policy, skills
        case toolsKnown = "tools_known"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        grouped = (try? container.decodeIfPresent(Bool.self, forKey: .grouped)) ?? false
        toolsKnown = (try? container.decodeIfPresent(Bool.self, forKey: .toolsKnown)) ?? false
        tools = try Self.lossy(ConnectorDetailTool.self, in: container, key: .tools)
        policy = (try? container.decodeIfPresent(ConnectorPolicy.self, forKey: .policy)) ?? ConnectorPolicy()
        skills = try Self.lossy(ConnectorSkill.self, in: container, key: .skills)
    }

    private static func lossy<Row: Decodable>(_ type: Row.Type, in container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> [Row] {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return [] }
        var rows = try container.nestedUnkeyedContainer(forKey: key)
        var found: [Row] = []
        while !rows.isAtEnd {
            if let row = try? rows.decode(Row.self) { found.append(row) } else { _ = try? rows.decode(DiscardedRow.self) }
        }
        return found
    }

    private struct DiscardedRow: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
