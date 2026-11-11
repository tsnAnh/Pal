import Foundation
import PalProtocol
import PalTransport

public struct ConnectorAccount: Decodable, Sendable, Equatable, Identifiable {
    public var connectionID: String
    public var connector: String
    public var status: String
    public var label: String
    public var alias: String?
    public var disabled: Bool

    public var id: String { connectionID }
    public var name: String { alias.flatMap { $0.isEmpty ? nil : $0 } ?? label }
    public var isRetired: Bool { disabled }
    public var needsReconnect: Bool { ["expired", "failed", "revoked", "inactive"].contains(status) }

    public init(connectionID: String, connector: String, status: String = "active", label: String, alias: String? = nil, disabled: Bool = false) {
        self.connectionID = connectionID
        self.connector = connector
        self.status = status
        self.label = label
        self.alias = alias
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case connector, status, label, alias, disabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try container.decode(String.self, forKey: .connectionID)
        connector = try container.decode(String.self, forKey: .connector)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "active"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

public enum ConnectorAlias {
    public enum Problem: Sendable, Equatable {
        case invalid
        case taken
    }

    public static func problem(_ alias: String, among accounts: [ConnectorAccount], renaming id: String) -> Problem? {
        let scalars = Array(alias.unicodeScalars)
        let valid = (1...32).contains(scalars.count)
            && scalars.enumerated().allSatisfy { index, scalar in
                let alnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
                return alnum || (index > 0 && scalar == "-")
            }
        guard valid else { return .invalid }
        return accounts.contains { $0.alias == alias && $0.connectionID != id } ? .taken : nil
    }
}

public struct HostedConnectorTool: Decodable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var description: String
    public var facet: String
    public var hints: [String]

    public var id: String { slug }

    enum CodingKeys: String, CodingKey { case slug, name, description, facet, hints }

    public init(slug: String, name: String, description: String = "", facet: String = "unclassified", hints: [String] = []) {
        self.slug = slug
        self.name = name
        self.description = description
        self.facet = facet
        self.hints = hints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? slug
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        facet = try container.decodeIfPresent(String.self, forKey: .facet) ?? "unclassified"
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
    }
}

public struct ConnectorPolicy: Sendable, Equatable {
    struct Rules: Sendable, Equatable {
        var allowed: Set<String>?
        var denied: Set<String>
        var revision: String
        var tools: [String: [String]]
        var enableTags: [String]
        var disableTags: [String]

        func allows(_ slug: String) -> Bool { (allowed?.contains(slug) ?? true) && !denied.contains(slug) }
    }

    var member: Rules?
    var others: [Rules]

    public static let empty = ConnectorPolicy(member: nil, others: [])

    public init(_ value: JSONValue) {
        let layers = value["layers"]?.arrayValue ?? []
        func rules(_ layer: JSONValue) -> Rules {
            let body = layer["body"] ?? .null
            let mode = body["mode"]?.stringValue
            let strings = { (key: String) in (body[key]?.arrayValue ?? []).compactMap(\.stringValue) }
            var tools: [String: [String]] = [:]
            for (slug, off) in body["tools"]?.objectValue ?? [:] { tools[slug] = (off.arrayValue ?? []).compactMap(\.stringValue) }
            let tags = body["tags"]
            var allowed: Set<String>?
            if mode == "deny-all" { allowed = [] } else if mode == "allow" { allowed = Set(strings("connectors")) }
            return Rules(
                allowed: allowed,
                denied: mode == "deny" ? Set(strings("disabled_connectors")) : [],
                revision: layer["revision"]?.stringValue ?? "",
                tools: tools,
                enableTags: (tags?["enable"]?.arrayValue ?? []).compactMap(\.stringValue),
                disableTags: (tags?["disable"]?.arrayValue ?? []).compactMap(\.stringValue)
            )
        }
        member = layers.first { $0["kind"]?.stringValue == "member" }.map(rules)
        others = layers.filter { $0["kind"]?.stringValue != "member" }.map(rules)
    }

    init(member: Rules?, others: [Rules]) {
        self.member = member
        self.others = others
    }

    public var revision: String? { member?.revision }

    public func memberEnables(_ slug: String) -> Bool { member?.allows(slug) ?? true }

    public func orgLocks(_ slug: String) -> Bool { others.contains { !$0.allows(slug) } }

    public func memberDisabledTools(_ slug: String) -> Set<String> { Set(member?.tools[slug] ?? []) }

    public func orgLockedTools(_ slug: String, among tools: [HostedConnectorTool]) -> Set<String> {
        var locked = Set<String>()
        for rules in others {
            locked.formUnion(rules.tools[slug] ?? [])
            for tool in tools {
                let hints = Set(tool.hints)
                let disabled = rules.disableTags.contains { hints.contains($0) }
                let missing = !rules.enableTags.isEmpty && !rules.enableTags.contains { hints.contains($0) }
                if disabled || missing { locked.insert(tool.slug) }
            }
        }
        return locked
    }
}

public enum ConnectorAccountsError: Error, Sendable, Equatable {
    case aliasTaken
    case aliasInvalid
    case notFound
    case policyChanged
    case readOnly
    case signInRequired
    case failed
}

extension ConnectAppsService {
    private func accountsCall(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            diagnostics.info("connect", "\(method) failed")
            throw Self.mapAccounts(error)
        }
    }

    static func mapAccounts(_ error: GatewayTransportError) -> ConnectorAccountsError {
        guard case .rpc(let rpc) = error else { return .failed }
        let reason = (rpc.data?["reason"]?.stringValue ?? rpc.data?["code"]?.stringValue)?.lowercased()
        switch reason {
        case "alias_taken": return .aliasTaken
        case "invalid_params": return .aliasInvalid
        case "connection_not_found": return .notFound
        case "policy_conflict": return .policyChanged
        case "needs_nous_auth": return .signInRequired
        case "forbidden_scope", "org_access_denied", "org_required": return .readOnly
        default: return .failed
        }
    }

    public func accounts(for slug: String) async throws -> [ConnectorAccount] {
        let result = try await accountsCall("connectors.accounts", ["connector": .string(slug)])
        guard let rows = result["accounts"]?.arrayValue else { throw ConnectorAccountsError.failed }
        return rows.compactMap { try? $0.decoded(as: ConnectorAccount.self) }.filter { $0.connector == slug }
    }

    public func renameAccount(_ connectionID: String, to alias: String) async throws -> ConnectorAccount {
        let result = try await accountsCall("connectors.accounts.rename", ["connection_id": .string(connectionID), "alias": .string(alias)])
        guard let account = try? result.decoded(as: ConnectorAccount.self) else { throw ConnectorAccountsError.failed }
        return account
    }

    public func removeAccount(_ connectionID: String) async throws {
        _ = try await accountsCall("connectors.accounts.remove", ["connection_id": .string(connectionID)])
    }

    public func connectorPolicy() async throws -> ConnectorPolicy {
        ConnectorPolicy(try await accountsCall("connectors.policy.get"))
    }

    public func connectorTools(for slug: String) async throws -> [HostedConnectorTool] {
        let result = try await accountsCall("connectors.tools", ["slug": .string(slug), "refresh": .bool(false)])
        guard let rows = result["tools"]?.arrayValue else { throw ConnectorAccountsError.failed }
        return rows.compactMap { try? $0.decoded(as: HostedConnectorTool.self) }
    }

    public func setConnectorEnabled(_ slug: String, enabled: Bool, policy: ConnectorPolicy) async throws {
        try await writePolicy(["type": "connector", "connector": .string(slug), "enabled": .bool(enabled)], policy: policy)
    }

    public func setDisabledTools(_ slug: String, disabled: Set<String>, policy: ConnectorPolicy) async throws {
        let change: JSONValue = ["type": "tools", "connector": .string(slug), "disabled_tools": .array(disabled.sorted().map(JSONValue.string))]
        try await writePolicy(change, policy: policy)
    }

    private func writePolicy(_ change: JSONValue, policy: ConnectorPolicy) async throws {
        guard let revision = policy.revision else { throw ConnectorAccountsError.readOnly }
        _ = try await accountsCall("connectors.policy.set", ["change": change, "expected_revision": .string(revision)])
    }
}
