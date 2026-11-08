import Foundation
import HermesAuth
import HermesConnect
import HermesProtocol
import HermesTransport
import Synchronization
import Testing

private let hostedEntries = [
    HostedConnectorEntry(slug: "slack", name: "Slack", description: "Read and post messages", category: "Communication"),
    HostedConnectorEntry(slug: "gmail", name: "Gmail", description: "Search and draft email", category: "Communication"),
    HostedConnectorEntry(slug: "github", name: "GitHub", description: "Issues and pull requests", category: "Developer"),
    HostedConnectorEntry(slug: "figma", name: "Figma", description: "Design files", category: "Design and media"),
    HostedConnectorEntry(slug: "odd", name: "Odd", description: "", category: "Zebra"),
    HostedConnectorEntry(slug: "bare", name: "Bare", description: "No category", category: ""),
]

@Suite("Connect catalog")
struct ConnectCatalogTests {
    @Test func categoriesComeFromTheCatalogInReadingOrderWithUnknownOnesLastBeforeOther() {
        let catalog = ConnectCatalog.make(hosted: hostedEntries, states: [], mcp: [McpPresetEntry(name: "algolia", description: "Search")])
        #expect(catalog.categories == ["Communication", "Design and media", "Developer", "Zebra", "Other"])
    }

    @Test func aConnectorWithoutACategoryLandsInOther() {
        let catalog = ConnectCatalog.make(hosted: hostedEntries, states: [], mcp: [])
        #expect(catalog.apps.first { $0.name == "Bare" }?.category == ConnectCatalog.otherCategory)
    }

    @Test func hostedStateFollowsTheAccountStatus() {
        let states = [
            HostedConnectorState(connector: "slack", connected: true, connectionStatus: "active"),
            HostedConnectorState(connector: "gmail", connected: true, connectionStatus: "expired"),
            HostedConnectorState(connector: "github", connected: true, connectionStatus: "revoked"),
            HostedConnectorState(connector: "figma", connected: false, connectionStatus: nil),
        ]
        let catalog = ConnectCatalog.make(hosted: hostedEntries, states: states, mcp: [])
        func state(_ name: String) -> ConnectAppState? { catalog.apps.first { $0.name == name }?.state }
        #expect(state("Slack") == .connected)
        #expect(state("Gmail") == .needsAuthorization)
        #expect(state("GitHub") == .disconnected)
        #expect(state("Figma") == .disconnected)
        #expect(catalog.connectedApps.map(\.name).sorted() == ["Gmail", "Slack"])
    }

    @Test func aPresetBackedByAHostedConnectorIsShownOnceAsTheHostedRow() {
        let mcp = [
            McpPresetEntry(name: "slack", description: "preset slack", connectorSlug: "slack", installed: true, enabled: true),
            McpPresetEntry(name: "linear", description: "Issues", connectorSlug: nil),
            McpPresetEntry(name: "stripe", description: "Payments", connectorSlug: "stripe-not-in-catalog"),
        ]
        let catalog = ConnectCatalog.make(hosted: hostedEntries, states: [], mcp: mcp)
        #expect(catalog.apps.filter { $0.name == "Slack" }.count == 1)
        #expect(catalog.apps.first { $0.name == "Slack" }?.source == .hosted(slug: "slack"))
        #expect(catalog.apps.map(\.id).contains("mcp:linear") && catalog.apps.map(\.id).contains("mcp:stripe"))
    }

    @Test func aStandalonePresetIsConnectedOnlyWhenInstalledAndEnabled() {
        let mcp = [
            McpPresetEntry(name: "on", description: "", installed: true, enabled: true),
            McpPresetEntry(name: "paused", description: "", installed: true, enabled: false),
            McpPresetEntry(name: "fresh", description: ""),
        ]
        let catalog = ConnectCatalog.make(hosted: [], states: [], mcp: mcp)
        #expect(catalog.apps.filter(\.isConnected).map(\.name) == ["On"])
    }

    @Test func presetSlugsBecomeReadableNames() {
        let catalog = ConnectCatalog.make(hosted: [], states: [], mcp: [McpPresetEntry(name: "hugging_face", description: ""), McpPresetEntry(name: "aws-knowledge", description: "")])
        #expect(Set(catalog.apps.map(\.name)) == ["Hugging Face", "Aws Knowledge"])
    }

    @Test func searchMatchesNameAndSummaryIgnoringCaseAndDiacritics() {
        let catalog = ConnectCatalog.make(hosted: hostedEntries, states: [], mcp: [])
        #expect(catalog.matching("SLACK").map(\.name) == ["Slack"])
        #expect(catalog.matching("pull requests").map(\.name) == ["GitHub"])
        #expect(catalog.matching("  ").count == hostedEntries.count)
        #expect(catalog.matching("zzz").isEmpty)
    }

    @Test func aNonHttpsLogoIsDropped() throws {
        let rows: JSONValue = [
            ["slug": "a", "name": "A", "description": "", "category": "Developer", "logo_url": "http://insecure.example/a.png"],
            ["slug": "b", "name": "B", "description": "", "category": "Developer", "logo_url": "https://logos.example/b.png"],
        ]
        let entries = try rows.arrayValue!.map { try $0.decoded(as: HostedConnectorEntry.self) }
        #expect(entries[0].logoURL == nil)
        #expect(entries[1].logoURL?.host == "logos.example")
    }
}

private final class ScriptedRPC: ConnectRPC {
    typealias Reply = @Sendable (JSONValue) throws -> JSONValue

    private let replies: Mutex<[String: Reply]>
    private let log = Mutex<[(String, JSONValue)]>([])

    init(_ replies: [String: Reply]) { self.replies = Mutex(replies) }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append((method, params)) }
        guard let reply = replies.withLock({ $0[method] }) else {
            throw GatewayTransportError.rpc(RPCError(code: -32601, message: "unknown_method"))
        }
        return try reply(params)
    }

    func methods() -> [String] { log.withLock { $0.map(\.0) } }
    func params(_ method: String) -> [JSONValue] { log.withLock { $0.filter { $0.0 == method }.map(\.1) } }
}

private struct NoBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws {}
    func dismiss() async {}
}

private func service(_ rpc: ScriptedRPC, profile: String? = nil) -> ConnectAppsService {
    ConnectAppsService(rpc: rpc, profile: profile, browser: NoBrowser(), timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3))
}

@Suite("Connect apps service")
struct ConnectAppsServiceTests {
    private let catalogReply: ScriptedRPC.Reply = { _ in
        ["connectors": [["slug": "slack", "name": "Slack", "description": "Chat", "category": "Communication"]]]
    }

    @Test func loadsAndMergesAllThreeSourcesWithTheScopedProfile() async throws {
        let rpc = ScriptedRPC([
            "connectors.catalog": catalogReply,
            "connectors.list": { _ in ["available": true, "connectors": [["connector": "slack", "connected": true, "connection_status": "active"]]] },
            "mcp.catalog": { _ in ["servers": [["name": "linear", "description": "Issues", "installed": false, "enabled": false, "requires": [], "transport": "x"]]] },
        ])
        let catalog = try await service(rpc, profile: "alpha").load()
        #expect(catalog.apps.map(\.name) == ["Linear", "Slack"])
        #expect(catalog.connectedApps.map(\.name) == ["Slack"])
        #expect(rpc.params("connectors.list").first?["profile"]?.stringValue == "alpha")
        #expect(rpc.params("connectors.list").first?["owner"]?["type"]?.stringValue == "account")
    }

    @Test func oneFailedSourceDoesNotHideTheOthers() async throws {
        let rpc = ScriptedRPC(["mcp.catalog": { _ in ["servers": [["name": "linear", "description": "", "installed": false, "enabled": false, "requires": [], "transport": "x"]]] }])
        let catalog = try await service(rpc).load()
        #expect(catalog.apps.map(\.id) == ["mcp:linear"])
    }

    @Test func everySourceFailingIsUnavailable() async {
        await #expect(throws: ConnectAppsError.unavailable) { try await service(ScriptedRPC([:])).load() }
    }

    @Test func hostedConnectWaitsForTheOperationToSettleConnected() async throws {
        let polls = Mutex(0)
        let rpc = ScriptedRPC([
            "connectors.connect": { _ in ["op_id": "op1", "settled": false, "targets": [["state": "initiated", "connect_url": "https://connect.example/start"]]] },
            "connectors.operation.wake": { _ in ["status": "ok"] },
            "connectors.operation.status": { _ in
                let count = polls.withLock { $0 += 1; return $0 }
                return ["op_id": "op1", "settled": .bool(count > 1), "targets": [["state": .string(count > 1 ? "connected" : "initiated")]]]
            },
        ])
        let app = ConnectApp(id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil, source: .hosted(slug: "slack"), state: .disconnected)
        try await service(rpc).connect(app)
        #expect(rpc.methods() == ["connectors.connect", "connectors.operation.wake", "connectors.operation.status", "connectors.operation.status"])
    }

    @Test func aFailedOperationIsAFailureNotASilentSuccess() async {
        let rpc = ScriptedRPC([
            "connectors.connect": { _ in ["op_id": "op1", "settled": false, "targets": [["state": "initiated"]]] },
            "connectors.operation.wake": { _ in ["status": "ok"] },
            "connectors.operation.status": { _ in ["op_id": "op1", "settled": true, "targets": [["state": "failed"]]] },
        ])
        let app = ConnectApp(id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil, source: .hosted(slug: "slack"), state: .disconnected)
        await #expect(throws: ConnectAppsError.failed) { try await service(rpc).connect(app) }
    }

    @Test func missingSignInIsReportedAsSuch() async {
        let rpc = ScriptedRPC(["connectors.connect": { _ in throw GatewayTransportError.rpc(RPCError(code: 5030, message: "x", data: ["code": "NEEDS_NOUS_AUTH"])) }])
        let app = ConnectApp(id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil, source: .hosted(slug: "slack"), state: .disconnected)
        await #expect(throws: ConnectAppsError.signInRequired) { try await service(rpc).connect(app) }
    }

    @Test func aPresetThatNeedsAKeyAsksForItBeforeTouchingTheGateway() async {
        let rpc = ScriptedRPC([:])
        let app = ConnectApp(id: "mcp:acme", name: "Acme", summary: "", category: "Other", iconURL: nil, source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected)
        await #expect(throws: ConnectAppsError.credentialsRequired(["ACME_KEY"])) { try await service(rpc).connect(app) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func aProvidedKeyIsStoredThroughTheKeyVerbAndNeverEchoedElsewhere() async throws {
        let rpc = ScriptedRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.set_api_key": { _ in ["ok": true] },
        ])
        let app = ConnectApp(id: "mcp:acme", name: "Acme", summary: "", category: "Other", iconURL: nil, source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected)
        try await service(rpc).connect(app, credentials: ["ACME_KEY": "s3cret-value"])
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.set_api_key"])
        #expect(rpc.params("mcp.servers.set_api_key").first?["env_var"]?.stringValue == "ACME_KEY")
        #expect(rpc.params("mcp.servers.add").map { "\($0)" }.joined().contains("s3cret-value") == false)
    }

    @Test func aFailedKeyWriteRemovesTheHalfInstalledServer() async {
        let rpc = ScriptedRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.set_api_key": { _ in throw GatewayTransportError.rpc(RPCError(code: 4001, message: "bad")) },
            "mcp.servers.remove": { _ in ["ok": true, "removed": true] },
        ])
        let app = ConnectApp(id: "mcp:acme", name: "Acme", summary: "", category: "Other", iconURL: nil, source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected)
        await #expect(throws: (any Error).self) { try await service(rpc).connect(app, credentials: ["ACME_KEY": "v"]) }
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func disconnectingAHostedConnectorRemovesEveryAccountItHas() async throws {
        let rpc = ScriptedRPC([
            "connectors.accounts": { _ in ["accounts": [["connection_id": "ca_1"], ["connection_id": "ca_2"]]] },
            "connectors.accounts.remove": { _ in ["connection_id": "x", "connector": "slack", "status": "removed"] },
        ])
        let app = ConnectApp(id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil, source: .hosted(slug: "slack"), state: .connected)
        try await service(rpc).disconnect(app)
        #expect(rpc.params("connectors.accounts.remove").compactMap { $0["connection_id"]?.stringValue } == ["ca_1", "ca_2"])
    }

    @Test func disconnectingAPresetRemovesItsServer() async throws {
        let rpc = ScriptedRPC(["mcp.servers.remove": { _ in ["ok": true, "removed": true] }])
        let app = ConnectApp(id: "mcp:linear", name: "Linear", summary: "", category: "Other", iconURL: nil, source: .mcp(name: "linear", requires: []), state: .connected)
        try await service(rpc).disconnect(app)
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "linear")
    }
}
