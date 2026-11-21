import Foundation
import PalProtocol

public enum ConnectorAccountState: String, Sendable, Hashable {
    case connected
    case needsReconnect = "needs_reconnect"
    case notConnected = "not_connected"

    public static func aggregate(_ accounts: [ConnectorAccount]) -> ConnectAppState? {
        if accounts.isEmpty { return nil }
        if accounts.contains(where: { $0.state == .connected }) { return .connected }
        return accounts.contains(where: { $0.state == .needsReconnect }) ? .needsAuthorization : .disconnected
    }

    var appState: ConnectAppState {
        switch self {
        case .connected: .connected
        case .needsReconnect: .needsAuthorization
        case .notConnected: .disconnected
        }
    }
}

public struct ConnectorAccount: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var state: ConnectorAccountState
    public var reason: String?

    public var id: String { name }

    public init(name: String, state: ConnectorAccountState, reason: String? = nil) {
        self.name = name
        self.state = state
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case name, reason
        case state = "status"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard ConnectorAccountName.isValid(name) else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "account name") }
        self.name = name
        let raw = try container.decodeIfPresent(String.self, forKey: .state)
        state = raw.flatMap(ConnectorAccountState.init(rawValue:)) ?? .notConnected
        reason = ConnectorCardState.cleaned(try? container.decodeIfPresent(String.self, forKey: .reason))
    }

    public func rowState(isBusy: Bool = false) -> ConnectRowState {
        ConnectRowState.resolve(ConnectRowInput(connection: state.appState, isBusy: isBusy, authReason: reason))
    }

    static func lossyList(from container: KeyedDecodingContainer<PalCatalogEntry.CodingKeys>) -> [ConnectorAccount] {
        guard var rows = try? container.nestedUnkeyedContainer(forKey: .accounts) else { return [] }
        var found: [ConnectorAccount] = []
        while !rows.isAtEnd {
            if let account = try? rows.decode(ConnectorAccount.self) { found.append(account) } else { _ = try? rows.decode(DiscardedRow.self) }
        }
        return found
    }

    private struct DiscardedRow: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

public struct ConnectorAccountTarget: Sendable, Equatable {
    public var name: String
    public var create: Bool
    public var selectsAccount: Bool

    public init(name: String, create: Bool, selectsAccount: Bool) {
        self.name = name
        self.create = create
        self.selectsAccount = selectsAccount
    }

    public static func adding(_ name: String, to app: ConnectApp) -> ConnectorAccountTarget {
        ConnectorAccountTarget(name: name, create: true, selectsAccount: !app.accounts.isEmpty)
    }

    public static func existing(_ name: String, in app: ConnectApp) -> ConnectorAccountTarget {
        ConnectorAccountTarget(name: name, create: false, selectsAccount: app.accounts.contains { $0.name != name })
    }

    func scoping(_ params: [String: JSONValue], create sendsCreate: Bool = false) -> [String: JSONValue] {
        var scoped = params
        scoped["account"] = .string(name)
        if sendsCreate, create { scoped["create"] = .bool(true) }
        return scoped
    }
}

extension ConnectApp {
    public var accounts: [ConnectorAccount] {
        if case .catalog(let entry) = source { entry.accounts } else { [] }
    }

    public var supportsAccounts: Bool {
        if case .catalog(let entry) = source { entry.multiAccount } else { false }
    }

    public var accountNames: [String] { accounts.map(\.name) }

    public var accountsNeedingReconnect: [ConnectorAccount] { accounts.filter { $0.state == .needsReconnect } }

    public func account(named name: String) -> ConnectorAccount? { accounts.first { $0.name == name } }
}
