import Foundation
import HermesAuth
import HermesConnect
import HermesProtocol
import HermesTransport
import Synchronization
import Testing

private final class AccountsRPC: ConnectRPC {
    typealias Reply = @Sendable (JSONValue) throws -> JSONValue
    private let replies: [String: Reply]
    private let log = Mutex<[(String, JSONValue)]>([])

    init(_ replies: [String: Reply]) { self.replies = replies }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append((method, params)) }
        guard let reply = replies[method] else { throw GatewayTransportError.rpc(RPCError(code: -32601, message: "unknown_method")) }
        return try reply(params)
    }

    func params(_ method: String) -> [JSONValue] { log.withLock { $0.filter { $0.0 == method }.map(\.1) } }
}

private func refusal(_ reason: String) -> GatewayTransportError {
    .rpc(RPCError(code: 4090, message: "refused", data: ["reason": .string(reason)]))
}

private func service(_ rpc: AccountsRPC, profile: String? = "work") -> ConnectAppsService {
    ConnectAppsService(rpc: rpc, profile: profile)
}

private func row(_ id: String, alias: String? = nil, connector: String = "slack", disabled: Bool = false) -> JSONValue {
    var object: [String: JSONValue] = [
        "connection_id": .string(id), "connector": .string(connector), "status": "active", "label": "me@example.com",
        "active": true, "disabled": .bool(disabled), "created_at": "t", "updated_at": "t",
    ]
    if let alias { object["alias"] = .string(alias) }
    return .object(object)
}

private func layer(_ kind: String, revision: String, body: JSONValue) -> JSONValue {
    ["kind": .string(kind), "revision": .string(revision), "body": body]
}

@Suite("Connector accounts")
struct ConnectorAccountsTests {
    @Test func listsOnlyThisConnectorsAccountsScopedToTheProfile() async throws {
        let rpc = AccountsRPC(["connectors.accounts": { _ in ["accounts": [row("a", alias: "work"), row("b", connector: "gmail")]] }])
        let accounts = try await service(rpc).accounts(for: "slack")
        #expect(accounts.map(\.id) == ["a"])
        #expect(accounts.first?.name == "work")
        #expect(rpc.params("connectors.accounts").first?["profile"]?.stringValue == "work")
        #expect(rpc.params("connectors.accounts").first?["connector"]?.stringValue == "slack")
    }

    @Test func renameSendsTheAliasAndReturnsTheNewRow() async throws {
        let rpc = AccountsRPC(["connectors.accounts.rename": { _ in row("a", alias: "team") }])
        let renamed = try await service(rpc).renameAccount("a", to: "team")
        #expect(renamed.alias == "team")
        #expect(rpc.params("connectors.accounts.rename").first?["alias"]?.stringValue == "team")
    }

    @Test func aTakenAliasIsReportedAsTaken() async {
        let rpc = AccountsRPC(["connectors.accounts.rename": { _ in throw refusal("ALIAS_TAKEN") }])
        await #expect(throws: ConnectorAccountsError.aliasTaken) { try await service(rpc).renameAccount("a", to: "team") }
    }

    @Test func aMissingAccountOnRemoveIsReportedAsNotFound() async {
        let rpc = AccountsRPC(["connectors.accounts.remove": { _ in throw refusal("CONNECTION_NOT_FOUND") }])
        await #expect(throws: ConnectorAccountsError.notFound) { try await service(rpc).removeAccount("a") }
    }

    @Test func removeSendsOnlyTheNamedConnection() async throws {
        let rpc = AccountsRPC(["connectors.accounts.remove": { _ in ["connection_id": "a", "connector": "slack", "status": "removed"] }])
        try await service(rpc).removeAccount("a")
        #expect(rpc.params("connectors.accounts.remove").map { $0["connection_id"]?.stringValue } == ["a"])
    }

    @Test func aliasRulesMatchTheGateway() {
        let accounts = [ConnectorAccount(connectionID: "a", connector: "slack", label: "x", alias: "work"), ConnectorAccount(connectionID: "b", connector: "slack", label: "y")]
        #expect(ConnectorAlias.problem("", among: accounts, renaming: "b") == .invalid)
        #expect(ConnectorAlias.problem("-x", among: accounts, renaming: "b") == .invalid)
        #expect(ConnectorAlias.problem("Work", among: accounts, renaming: "b") == .invalid)
        #expect(ConnectorAlias.problem(String(repeating: "a", count: 33), among: accounts, renaming: "b") == .invalid)
        #expect(ConnectorAlias.problem("work", among: accounts, renaming: "b") == .taken)
        #expect(ConnectorAlias.problem("work", among: accounts, renaming: "a") == nil)
        #expect(ConnectorAlias.problem("team-2", among: accounts, renaming: "b") == nil)
    }
}

@Suite("Connector policy")
struct ConnectorPolicyTests {
    private let policyReply: AccountsRPC.Reply = { _ in
        [
            "layers": [
                layer("org", revision: "o1", body: ["mode": "deny", "disabled_connectors": ["gmail"], "tools": ["slack": ["post"]], "tags": ["disable": ["admin"]]]),
                layer("member", revision: "m1", body: ["mode": "deny", "disabled_connectors": ["github"], "tools": ["slack": ["delete"]]]),
            ],
        ]
    }

    @Test func readsTheMemberLayerAndTheOrganizationLocks() {
        let policy = ConnectorPolicy(try! policyReply(.null))
        #expect(policy.revision == "m1")
        #expect(!policy.memberEnables("github") && policy.memberEnables("slack"))
        #expect(policy.orgLocks("gmail") && !policy.orgLocks("slack"))
        #expect(policy.memberDisabledTools("slack") == ["delete"])
        let tools = [HostedConnectorTool(slug: "post", name: "Post"), HostedConnectorTool(slug: "ban", name: "Ban", hints: ["admin"]), HostedConnectorTool(slug: "read", name: "Read")]
        #expect(policy.orgLockedTools("slack", among: tools) == ["post", "ban"])
    }

    @Test func aDenyAllMemberLayerEnablesNothing() {
        let policy = ConnectorPolicy(["layers": [layer("member", revision: "m", body: ["mode": "deny-all"])]])
        #expect(!policy.memberEnables("slack"))
    }

    @Test func writesSendTheSeenRevisionAndTheExactChange() async throws {
        let rpc = AccountsRPC(["connectors.policy.set": { _ in ["revision": "m2", "effective": ["mode": "unrestricted"]] }])
        let policy = ConnectorPolicy(try policyReply(.null))
        try await service(rpc).setConnectorEnabled("github", enabled: true, policy: policy)
        try await service(rpc).setDisabledTools("slack", disabled: ["b", "a"], policy: policy)
        let sent = rpc.params("connectors.policy.set")
        #expect(sent.map { $0["expected_revision"]?.stringValue } == ["m1", "m1"])
        #expect(sent[0]["change"]?["type"]?.stringValue == "connector" && sent[0]["change"]?["enabled"]?.boolValue == true)
        #expect(sent[1]["change"]?["disabled_tools"]?.arrayValue?.compactMap(\.stringValue) == ["a", "b"])
    }

    @Test func withoutAMemberLayerNothingIsWritten() async {
        let rpc = AccountsRPC([:])
        await #expect(throws: ConnectorAccountsError.readOnly) {
            try await service(rpc).setConnectorEnabled("slack", enabled: false, policy: .empty)
        }
        #expect(rpc.params("connectors.policy.set").isEmpty)
    }

    @Test func aConflictAndAForbiddenWriteAreDistinguished() async {
        let conflict = AccountsRPC(["connectors.policy.set": { _ in throw refusal("POLICY_CONFLICT") }])
        let forbidden = AccountsRPC(["connectors.policy.set": { _ in throw refusal("FORBIDDEN_SCOPE") }])
        let policy = ConnectorPolicy(try! policyReply(.null))
        await #expect(throws: ConnectorAccountsError.policyChanged) { try await service(conflict).setConnectorEnabled("slack", enabled: false, policy: policy) }
        await #expect(throws: ConnectorAccountsError.readOnly) { try await service(forbidden).setConnectorEnabled("slack", enabled: false, policy: policy) }
    }
}
