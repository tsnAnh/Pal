import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let catalogEntries = [
    catalogEntry("slack", "Slack", "Communication", method: .mcpOAuth),
    catalogEntry("gmail", "Gmail", "Communication", method: .mcpOAuth),
    catalogEntry("github", "GitHub", "Developer tools", method: .apiKey),
    catalogEntry("figma", "Figma", "Design and web", method: .mcpOAuth),
    catalogEntry("odd", "Odd", "Zebra"),
    catalogEntry("bare", "Bare", ""),
    catalogEntry("upwork", "Upwork", "Sales and support", method: .native, url: nil),
    catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .native, url: nil),
    catalogEntry("acme", "Acme", "Developer tools", method: .oauthClient, status: .needsSetup, url: nil),
]

@Suite("Connect catalog")
struct ConnectCatalogTests {
    @Test func categoriesComeFromTheCatalogInReadingOrderWithUnknownOnesLastBeforeOther() {
        let catalog = ConnectCatalog.make(catalog: catalogEntries, mcp: [])
        #expect(catalog.categories == ["Developer tools", "Design and web", "Communication", "Zebra", "Other"])
    }

    @Test func everyShippedCategoryHasAFixedPlaceInTheList() {
        let shipped = [
            "Other", "Communication", "Finance", "Sales and support", "Design and web", "Docs and files", "Work management",
            "Monitoring and analytics", "Hosting and infrastructure", "Developer tools",
        ]
        let catalog = ConnectCatalog.make(catalog: shipped.enumerated().map { catalogEntry("c\($0.offset)", "C\($0.offset)", $0.element) }, mcp: [])
        #expect(catalog.categories == [
            "Developer tools", "Hosting and infrastructure", "Monitoring and analytics", "Work management", "Docs and files",
            "Design and web", "Sales and support", "Finance", "Communication", "Other",
        ])
    }

    @Test func aConnectorWithoutACategoryLandsInOther() {
        let catalog = ConnectCatalog.make(catalog: catalogEntries, mcp: [])
        #expect(catalog.apps.first { $0.name == "Bare" }?.category == ConnectCatalog.otherCategory)
    }

    @Test func nativeRowsAndTheGoogleRowAreNotListedFromTheCatalog() {
        let catalog = ConnectCatalog.make(catalog: catalogEntries, mcp: [])
        #expect(!catalog.apps.map(\.id).contains("connector:upwork"))
        #expect(!catalog.apps.map(\.id).contains("connector:google-workspace"))
    }

    @Test func theStatusDecidesTheRowState() {
        let rows = [
            catalogEntry("a", "A", "Developer", status: .connected),
            catalogEntry("b", "B", "Developer", status: .needsReconnect),
            catalogEntry("c", "C", "Developer", status: .notConnected),
            catalogEntry("d", "D", "Developer", method: .oauthClient, status: .needsSetup, url: nil),
        ]
        let catalog = ConnectCatalog.make(catalog: rows, mcp: [])
        func state(_ name: String) -> ConnectAppState? { catalog.apps.first { $0.name == name }?.state }
        #expect(state("A") == .connected)
        #expect(state("B") == .needsAuthorization)
        #expect(state("C") == .disconnected)
        #expect(state("D") == .needsSetup)
        #expect(catalog.connectedApps.map(\.name).sorted() == ["A", "B"])
        #expect(catalog.apps.first { $0.name == "D" }?.summary == "Needs setup on your Pal before it can connect.")
        #expect(ConnectAppStatus(.needsSetup) == .notConnected)
    }

    @Test func onlyCatalogRowsAndTheOwnersCustomServersAreListed() {
        let mcp = [
            McpPresetEntry(name: "slack", description: "preset slack", connectorSlug: nil, installed: true, enabled: true),
            McpPresetEntry(name: "gmail-preset", description: "", connectorSlug: "gmail"),
            McpPresetEntry(name: "linear", description: "Issues", connectorSlug: nil),
            McpPresetEntry(name: "upwork", description: "Upwork", connectorSlug: "upwork"),
        ]
        let servers = [
            McpServerEntry(name: "figma", url: "https://mcp.figma.example/mcp"), McpServerEntry(name: "mine", url: "https://mine.example/mcp"),
            McpServerEntry(name: "linear", url: "https://mcp.linear.example/mcp"),
        ]
        let catalog = ConnectCatalog.make(catalog: catalogEntries, mcp: mcp, servers: servers)
        #expect(catalog.apps.filter { $0.name == "Slack" }.count == 1)
        #expect(catalog.apps.first { $0.name == "Slack" }?.source == .catalog(catalogEntries[0]))
        let ids = catalog.apps.map(\.id)
        #expect(!ids.contains { $0.hasPrefix("mcp:") })
        #expect(ids.contains("custom:mine"))
        #expect(!ids.contains("custom:figma") && !ids.contains("custom:linear"))
    }

    @Test func aPresetOutsideTheCatalogNeverBecomesARow() {
        let presets = [McpPresetEntry(name: "hugging_face", description: "", installed: true, enabled: true), McpPresetEntry(name: "algolia", description: "")]
        #expect(ConnectCatalog.make(catalog: [], mcp: presets).apps.isEmpty)
    }

    @Test func anUnverifiedRowSaysItMayNotConnectUnlessASetupSummaryApplies() {
        let unverified = PalCatalogEntry(slug: "craft", name: "Craft", method: .none, verified: false)
        let needsSetup = PalCatalogEntry(slug: "slack", name: "Slack", method: .oauthClient, verified: false, status: .needsSetup)
        let verified = catalogEntry("deepwiki", "DeepWiki", "Developer")
        let apps = ConnectCatalog.make(catalog: [unverified, needsSetup, verified], mcp: []).apps
        #expect(apps.first { $0.name == "Craft" }?.summary == "Not verified: may not connect")
        #expect(apps.first { $0.name == "Slack" }?.summary == "Needs setup on your Pal before it can connect.")
        #expect(apps.first { $0.name == "DeepWiki" }?.summary == "")
    }

    @Test func searchMatchesNameIgnoringCaseAndDiacritics() {
        let catalog = ConnectCatalog.make(catalog: catalogEntries, mcp: [])
        #expect(catalog.matching("SLACK").map(\.name) == ["Slack"])
        #expect(catalog.matching("  ").count == catalog.apps.count)
        #expect(catalog.matching("zzz").isEmpty)
    }

    @Test func installedSkillsAreSearchableByNameAndCategory() {
        let skills = InstalledSkill.parse(["skills": ["apple": ["apple-reminders", "findmy"], "email": ["himalaya"]]])
        let catalog = ConnectCatalog.make(catalog: [], mcp: [], skills: skills)
        #expect(catalog.matchingSkills("remind").map(\.name) == ["apple-reminders"])
        #expect(catalog.matchingSkills("email").map(\.name) == ["himalaya"])
        #expect(catalog.matchingSkills("").isEmpty)
    }

    @Test func onlyLocallyCreatedSkillsArePrivateAndCarryTheirDescription() {
        let payload: JSONValue = [
            "skills": ["notes": ["weekly-review", "release-notes"], "apple": ["findmy"], "mcp": ["linear"], "dev": ["external-one"]],
            "details": [
                ["name": "weekly-review", "description": "  Summarise the week  ", "origin": "local"],
                ["name": "release-notes", "description": "Draft release notes", "origin": "hub"],
                ["name": "findmy", "description": "Find devices", "origin": "bundled"],
                ["name": "linear", "origin": "local"],
                ["name": "external-one", "description": "From a read-only dir", "origin": "external"],
            ],
        ]
        let catalog = ConnectCatalog.make(catalog: [], mcp: [], skills: InstalledSkill.parse(payload))
        #expect(catalog.privateSkills.map(\.name) == ["linear", "weekly-review"])
        #expect(catalog.privateSkills.first { $0.name == "weekly-review" }?.description == "Summarise the week")
        #expect(catalog.privateSkills.first { $0.name == "linear" }?.description == "")
        #expect(catalog.skills.count == 5)
    }

    @Test func anOlderGatewayWithoutDetailsOrWithAnUnknownOriginHasNoPrivateSkills() {
        let older = InstalledSkill.parse(["skills": ["notes": ["a"], "dev": ["b"]]])
        #expect(older.count == 2 && older.allSatisfy { !$0.isLocal && $0.description.isEmpty })
        let unknown = InstalledSkill.parse(["skills": ["notes": ["a"]], "details": [["name": "a", "origin": "somewhere-new"]]])
        #expect(ConnectCatalog.make(catalog: [], mcp: [], skills: unknown).privateSkills.isEmpty)
        let malformed = InstalledSkill.parse(["skills": ["notes": ["a"]], "details": [["description": "x"], "oops", ["name": 3, "origin": "local"]]])
        #expect(malformed.allSatisfy { !$0.isLocal })
    }

    @Test func theGatewayPayloadDecodesAndDropsRowsWithAnUnreadableStatus() throws {
        let rows: JSONValue = [
            [
                "slug": "a", "name": "A", "description": "", "category": "Developer", "icon": "plugin_glyph", "method": "mcp_oauth",
                "verified": true, "mcp_url": "https://a.example/mcp", "logo_url": nil, "status": "needs_reconnect",
            ],
            [
                "slug": "b", "name": "B", "category": "Developer", "icon": "plugin_glyph", "method": "none",
                "verified": false, "mcp_url": "http://insecure.example/mcp", "status": "not_connected",
            ],
            ["slug": "d", "name": "D", "category": "Developer", "method": "api_key", "status": "maybe"],
        ]
        let entries = rows.arrayValue!.compactMap { try? $0.decoded(as: PalCatalogEntry.self) }
        #expect(entries.map(\.slug) == ["a", "b"])
        #expect(entries[0].method == .mcpOAuth && entries[0].status == .needsReconnect && entries[0].mcpURL?.host == "a.example")
        #expect(entries[1].mcpURL == nil)
    }

    @Test(arguments: [
        ("mcp_oauth", PalCatalogEntry.Method.mcpOAuth), ("none", .none), ("api_key", .apiKey), ("native", .native),
        ("oauth_client", .oauthClient), ("bot_app", .botApp), ("telepathy", .unsupported("telepathy")),
    ])
    func everyMethodDecodesAndAnUnknownOneIsKeptAsUnsupported(raw: String, expected: PalCatalogEntry.Method) throws {
        let row: JSONValue = ["slug": "x", "name": "X", "category": "Developer", "method": .string(raw), "status": "not_connected"]
        #expect(try row.decoded(as: PalCatalogEntry.self).method == expected)
    }

    @Test func aCatalogWithAMethodThisBuildDoesNotKnowStillListsEveryEntry() throws {
        let oldShape: JSONValue = [
            ["slug": "a", "name": "A", "category": "Developer", "method": "oauth_client", "status": "needs_setup"],
            ["slug": "b", "name": "B", "category": "Developer", "method": "mcp_oauth", "status": "not_connected"],
        ]
        let newShape: JSONValue = [
            ["slug": "a", "name": "A", "category": "Developer", "method": "from_the_future", "status": "not_connected"],
            ["slug": "b", "name": "B", "category": "Developer", "method": "mcp_oauth", "status": "not_connected"],
        ]
        for rows in [oldShape, newShape] {
            let entries = try rows.arrayValue!.map { try $0.decoded(as: PalCatalogEntry.self) }
            let apps = ConnectCatalog.make(catalog: entries, mcp: []).apps
            #expect(apps.map(\.name) == ["A", "B"])
        }
        let future = try newShape.arrayValue![0].decoded(as: PalCatalogEntry.self)
        let app = try #require(ConnectCatalog.make(catalog: [future], mcp: []).apps.first)
        #expect(app.state == .needsSetup && app.summary == "Needs a newer Pal" && app.oauthClientEntry == nil)
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
        ["connectors": [[
            "slug": "slack", "name": "Slack", "description": "", "category": "Communication", "icon": "plugin_glyph", "method": "mcp_oauth",
            "verified": true, "mcp_url": "https://mcp.slack.example/mcp", "status": "connected",
        ]]]
    }

    private let forbidden = [
        "connectors.connect", "connectors.list", "connectors.accounts", "connectors.accounts.remove",
        "connectors.operation.wake", "connectors.operation.status",
    ]

    @Test func loadsAndMergesAllSourcesWithTheScopedProfileWithoutReadingAccountStatus() async throws {
        let rpc = ScriptedRPC([
            "connectors.catalog": catalogReply,
            "mcp.catalog": { _ in ["servers": [["name": "linear", "description": "Issues", "installed": false, "enabled": false, "requires": [], "transport": "x"]]] },
        ])
        let catalog = try await service(rpc, profile: "alpha").load()
        #expect(catalog.apps.map(\.name) == ["Slack"])
        #expect(catalog.connectedApps.map(\.name) == ["Slack"])
        #expect(rpc.params("connectors.catalog").first?["profile"]?.stringValue == "alpha")
        #expect(Set(rpc.methods()).isDisjoint(with: forbidden))
    }

    @Test func oneFailedSourceDoesNotHideTheOthers() async throws {
        let rpc = ScriptedRPC(["mcp.catalog": { _ in ["servers": [["name": "linear", "description": "", "installed": false, "enabled": false, "requires": [], "transport": "x"]]] }])
        let catalog = try await service(rpc).load()
        #expect(catalog.apps.isEmpty)
    }

    @Test func everySourceFailingIsUnavailable() async {
        await #expect(throws: ConnectAppsError.unavailable) { try await service(ScriptedRPC([:])).load() }
    }

    @Test func aPresetThatNeedsAKeyAsksForItBeforeTouchingTheGateway() async {
        let rpc = ScriptedRPC([:])
        let app = ConnectApp(
            id: "mcp:acme", name: "Acme", summary: "", category: "Other",
            source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected
        )
        await #expect(throws: ConnectAppsError.credentialsRequired(["ACME_KEY"])) { try await service(rpc).connect(app) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func aProvidedKeyIsStoredThroughTheKeyVerbAndNeverEchoedElsewhere() async throws {
        let rpc = ScriptedRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.set_api_key": { _ in ["ok": true] },
        ])
        let app = ConnectApp(
            id: "mcp:acme", name: "Acme", summary: "", category: "Other",
            source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected
        )
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
        let app = ConnectApp(
            id: "mcp:acme", name: "Acme", summary: "", category: "Other",
            source: .mcp(name: "acme", requires: ["ACME_KEY"]), state: .disconnected
        )
        await #expect(throws: (any Error).self) { try await service(rpc).connect(app, credentials: ["ACME_KEY": "v"]) }
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func disconnectingAPresetRemovesItsServer() async throws {
        let rpc = ScriptedRPC(["mcp.servers.remove": { _ in ["ok": true, "removed": true] }])
        let app = ConnectApp(id: "mcp:linear", name: "Linear", summary: "", category: "Other", source: .mcp(name: "linear", requires: []), state: .connected)
        try await service(rpc).disconnect(app)
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "linear")
    }

    @Test func updatingTheTokenOfAnAddedServerKeepsTheServerEvenWhenTheWriteFails() async {
        let rpc = ScriptedRPC([
            "mcp.servers.add": { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) },
            "mcp.servers.set_api_key": { _ in throw GatewayTransportError.rpc(RPCError(code: 4001, message: "bad")) },
        ])
        let app = ConnectApp(
            id: "mcp:github", name: "Github", summary: "", category: "Other",
            source: .mcp(name: "github", requires: ["MCP_GITHUB_API_KEY"]), state: .connected
        )
        await #expect(throws: (any Error).self) { try await service(rpc).connect(app, credentials: ["MCP_GITHUB_API_KEY": "v"]) }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aRefusedTokenIsReportedAfterTheServerTestsIt() async {
        let rpc = ScriptedRPC(["mcp.servers.test": { _ in ["ok": false, "reason": "auth_refused", "tools": []] }])
        let app = ConnectApp(
            id: "mcp:github", name: "Github", summary: "", category: "Other",
            source: .mcp(name: "github", requires: ["MCP_GITHUB_API_KEY"]), state: .connected
        )
        #expect(await service(rpc).tokenFailure(app) == .authRefused)
    }
}
