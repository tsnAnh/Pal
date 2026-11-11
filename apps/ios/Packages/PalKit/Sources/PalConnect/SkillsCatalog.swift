import Foundation
import PalProtocol

public enum SkillState: Sendable, Equatable {
    case available
    case installed
    case updateAvailable
}

public enum SkillFilter: Sendable, CaseIterable, Hashable {
    case all
    case installed
    case updates
}

public struct SkillHubItem: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var source: String?
    public var trust: String?
    public var identifier: String?

    public init(name: String, summary: String = "", source: String? = nil, trust: String? = nil, identifier: String? = nil) {
        self.name = name
        self.summary = summary
        self.source = source
        self.trust = trust
        self.identifier = identifier
    }

    static func parse(_ value: JSONValue, key: String) -> [SkillHubItem] {
        (value[key]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue?.nonBlank else { return nil }
            return SkillHubItem(
                name: name, summary: row["description"]?.stringValue?.trimmed ?? "", source: row["source"]?.stringValue?.nonBlank,
                trust: row["trust"]?.stringValue?.nonBlank, identifier: row["identifier"]?.stringValue?.nonBlank
            )
        }
    }
}

public struct HubInstalledSkill: Sendable, Equatable {
    public var name: String
    public var identifier: String?
    public var source: String?
    public var trustLevel: String?

    public init(name: String, identifier: String? = nil, source: String? = nil, trustLevel: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.source = source
        self.trustLevel = trustLevel
    }

    static func parse(_ value: JSONValue) -> [HubInstalledSkill] {
        (value["installed_skills"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue?.nonBlank else { return nil }
            return HubInstalledSkill(
                name: name, identifier: row["identifier"]?.stringValue?.nonBlank, source: row["source"]?.stringValue?.nonBlank,
                trustLevel: row["trust_level"]?.stringValue?.nonBlank
            )
        }
    }
}

public struct SkillUpdateStatus: Sendable, Equatable {
    public static let updateAvailable = "update_available"

    public var name: String
    public var identifier: String?
    public var status: String

    public init(name: String, identifier: String? = nil, status: String) {
        self.name = name
        self.identifier = identifier
        self.status = status
    }

    static func parse(_ value: JSONValue) -> [SkillUpdateStatus] {
        (value["updates"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue?.nonBlank, let status = row["status"]?.stringValue else { return nil }
            return SkillUpdateStatus(name: name, identifier: row["identifier"]?.stringValue?.nonBlank, status: status)
        }
    }
}

public struct SkillsInstallState: Sendable, Equatable {
    public static let empty = SkillsInstallState()

    public var hubInstalled: [HubInstalledSkill]
    public var bundled: [InstalledSkill]
    public var updates: [SkillUpdateStatus]

    public init(hubInstalled: [HubInstalledSkill] = [], bundled: [InstalledSkill] = [], updates: [SkillUpdateStatus] = []) {
        self.hubInstalled = hubInstalled
        self.bundled = bundled
        self.updates = updates
    }
}

public struct SkillRow: Identifiable, Sendable, Equatable {
    public var name: String
    public var summary: String
    public var source: String?
    public var trust: String?
    public var identifier: String?
    public var state: SkillState
    public var managedName: String?

    public var id: String { identifier ?? "name:\(name.lowercased())" }

    public var installTarget: String { identifier ?? name }

    public var isInstalled: Bool { state != .available }

    public var isRemovable: Bool { managedName != nil }

    public init(
        name: String, summary: String = "", source: String? = nil, trust: String? = nil, identifier: String? = nil,
        state: SkillState = .available, managedName: String? = nil
    ) {
        self.name = name
        self.summary = summary
        self.source = source
        self.trust = trust
        self.identifier = identifier
        self.state = state
        self.managedName = managedName
    }
}

public struct SkillsCatalog: Sendable, Equatable {
    public private(set) var rows: [SkillRow]
    private let installState: SkillsInstallState

    public init(hub: [SkillHubItem] = [], state: SkillsInstallState = .empty, includeUnlisted: Bool = true) {
        installState = state
        var rows: [SkillRow] = []
        var matched = Set<Int>()
        for item in hub {
            let index = state.hubInstalled.firstIndex { Self.same(item, $0) }
            if let index { matched.insert(index) }
            let installed = index.map { state.hubInstalled[$0] }
            rows.append(SkillRow(
                name: item.name, summary: item.summary, source: item.source ?? installed?.source, trust: item.trust ?? installed?.trustLevel,
                identifier: item.identifier ?? installed?.identifier, state: Self.state(of: installed, updates: state.updates),
                managedName: installed?.name
            ))
        }
        if includeUnlisted {
            for (index, installed) in state.hubInstalled.enumerated() where !matched.contains(index) {
                rows.append(SkillRow(
                    name: installed.name, source: installed.source, trust: installed.trustLevel, identifier: installed.identifier,
                    state: Self.state(of: installed, updates: state.updates), managedName: installed.name
                ))
            }
            let known = Set(rows.map { $0.name.lowercased() })
            for local in state.bundled where !known.contains(local.name.lowercased()) {
                rows.append(SkillRow(name: local.name, summary: local.category, state: .installed))
            }
        }
        var seen = Set<String>()
        self.rows = rows.filter { seen.insert($0.id).inserted }
    }

    private static func same(_ item: SkillHubItem, _ installed: HubInstalledSkill) -> Bool {
        if let lhs = item.identifier, let rhs = installed.identifier { return lhs == rhs }
        return item.name.caseInsensitiveCompare(installed.name) == .orderedSame
    }

    private static func state(of installed: HubInstalledSkill?, updates: [SkillUpdateStatus]) -> SkillState {
        guard let installed else { return .available }
        let hasUpdate = updates.contains { update in
            guard update.status == SkillUpdateStatus.updateAvailable else { return false }
            if let lhs = update.identifier, let rhs = installed.identifier { return lhs == rhs }
            return update.name.caseInsensitiveCompare(installed.name) == .orderedSame
        }
        return hasUpdate ? .updateAvailable : .installed
    }

    public var updatableCount: Int { rows.filter { $0.state == .updateAvailable }.count }

    public func rows(filter: SkillFilter, query: String = "") -> [SkillRow] {
        Self.apply(filter, query: query, to: rows)
    }

    public func results(for query: String, filter: SkillFilter, remote: [SkillHubItem]) -> [SkillRow] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return rows(filter: filter) }
        let hits = SkillsCatalog(hub: remote, state: installState, includeUnlisted: false).rows
        var seenIDs = Set(hits.map(\.id))
        var seenNames = Set(hits.map { $0.name.lowercased() })
        let local = Self.apply(.all, query: needle, to: rows).filter { row in
            !seenIDs.contains(row.id) && !seenNames.contains(row.name.lowercased())
        }
        for row in local {
            seenIDs.insert(row.id)
            seenNames.insert(row.name.lowercased())
        }
        return Self.apply(filter, query: "", to: hits + local)
    }

    private static func apply(_ filter: SkillFilter, query: String, to rows: [SkillRow]) -> [SkillRow] {
        let needle = query.trimmed
        return rows.filter { row in
            switch filter {
            case .all: break
            case .installed: if !row.isInstalled { return false }
            case .updates: if row.state != .updateAvailable { return false }
            }
            guard !needle.isEmpty else { return true }
            return row.name.localizedStandardContains(needle) || row.summary.localizedStandardContains(needle)
                || (row.source?.localizedStandardContains(needle) ?? false)
        }
    }
}

public struct SkillDetail: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var source: String?
    public var identifier: String?
    public var tags: [String]
    public var requirements: SkillRequirements

    public init(
        name: String, summary: String = "", source: String? = nil, identifier: String? = nil, tags: [String] = [],
        requirements: SkillRequirements = SkillRequirements()
    ) {
        self.name = name
        self.summary = summary
        self.source = source
        self.identifier = identifier
        self.tags = tags
        self.requirements = requirements
    }

    static func parse(_ value: JSONValue) -> SkillDetail? {
        guard let info = value["info"], let name = info["name"]?.stringValue?.nonBlank else { return nil }
        return SkillDetail(
            name: name, summary: info["description"]?.stringValue?.trimmed ?? "", source: info["source"]?.stringValue?.nonBlank,
            identifier: info["identifier"]?.stringValue?.nonBlank,
            tags: (info["tags"]?.arrayValue ?? []).compactMap { $0.stringValue?.nonBlank },
            requirements: SkillRequirements.parse(skillMarkdown: info["skill_md_preview"]?.stringValue ?? "")
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
