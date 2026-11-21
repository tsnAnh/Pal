import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

private let groupedJSON = """
{
  "slug": "upwork", "grouped": true, "tools_known": true,
  "tools": [
    {"name": "search_jobs", "title": "Search jobs", "description": "Find jobs", "group": "read"},
    {"name": "get_job", "title": "Get job", "description": "", "group": "read"},
    {"name": "send_proposal", "title": "Send proposal", "description": "Apply", "group": "write"},
    {"name": "pay_invoice", "title": "Pay invoice", "description": "", "group": "never"}
  ],
  "policy": {"read": "auto", "write": "ask"},
  "skills": [{"name": "triage", "title": "Triage new issues", "description": "Sort issues"}]
}
"""

private let ungroupedJSON = """
{
  "slug": "linear", "grouped": false, "tools_known": true,
  "tools": [{"name": "create_issue", "title": "Create issue", "description": "", "group": "tool"}],
  "policy": {"tool": "on"}, "skills": []
}
"""

private func details(_ json: String) throws -> ConnectorDetails {
    try JSONDecoder().decode(ConnectorDetails.self, from: Data(json.utf8))
}

private func service(_ rpc: CustomRPC, profile: String? = nil) -> ConnectAppsService { customService(rpc, profile: profile) }

private func catalogEntry(
    source: String? = nil, mcp: String = "https://user:pw@mcp.linear.app/sse?token=abc#frag", method: PalCatalogEntry.Method = .mcpOAuth,
    verified: Bool = true, category: String = "Work management", accounts: [ConnectorAccount] = []
) throws -> ConnectApp {
    var row: [String: JSONValue] = [
        "slug": "linear", "name": "Linear", "category": .string(category), "method": .string(wireMethod(method)), "verified": .bool(verified),
        "status": "connected", "mcp_url": .string(mcp), "multi_account": true,
    ]
    if let source { row["source"] = .string(source) }
    row["accounts"] = .array(accounts.map { ["name": .string($0.name), "status": .string($0.state.rawValue)] })
    let entry = try JSONValue.object(row).decoded(as: PalCatalogEntry.self)
    return ConnectCatalog.make(catalog: [entry], mcp: []).apps[0]
}

private func wireMethod(_ method: PalCatalogEntry.Method) -> String {
    switch method {
    case .mcpOAuth: "mcp_oauth"
    case .apiKey: "api_key"
    case .oauthClient: "oauth_client"
    default: "none"
    }
}

@Suite("Connector details wire")
struct ConnectorDetailsWireTests {
    @Test func groupedDetailsKeepGroupsAndPolicy() throws {
        let decoded = try details(groupedJSON)
        #expect(decoded.grouped && decoded.toolsKnown)
        #expect(decoded.tools.map(\.group) == [.read, .read, .write, .never])
        #expect(decoded.policy.mode(for: .read) == .auto)
        #expect(decoded.policy.mode(for: .write) == .ask)
        #expect(decoded.skills.map(\.title) == ["Triage new issues"])
    }

    @Test func ungroupedDetailsUseTheToolGroup() throws {
        let decoded = try details(ungroupedJSON)
        #expect(!decoded.grouped)
        #expect(decoded.tools.allSatisfy { $0.group == .tool })
        #expect(decoded.policy.mode(for: .tool) == .on)
    }

    @Test func olderGatewayPayloadWithoutNewFieldsDecodesEmpty() throws {
        let decoded = try details(#"{"slug": "linear"}"#)
        #expect(decoded.tools.isEmpty && decoded.skills.isEmpty)
        #expect(!decoded.grouped && !decoded.toolsKnown)
        #expect(ConnectorDetailsLayout.toolSections(decoded).isEmpty)
    }

    @Test func rowsWithUnknownGroupOrNoNameAreDropped() throws {
        let decoded = try details(
            """
            {"slug": "x", "tools_known": true, "tools": [
              {"name": "ok", "title": "Ok", "group": "read"},
              {"name": "odd", "title": "Odd", "group": "banana"},
              {"name": "", "title": "Blank", "group": "read"},
              {"title": "Nameless", "group": "read"},
              {"name": "bare", "group": "read"}
            ], "skills": [{"title": "No name"}, {"name": "s", "title": "S"}]}
            """
        )
        #expect(decoded.tools.map(\.name) == ["ok", "bare"])
        #expect(decoded.tools.last?.title == "bare")
        #expect(decoded.skills.map(\.name) == ["s"])
    }

    @Test func policyModeInvalidForItsGroupFallsBackToTheSafeDefault() throws {
        let decoded = try details(#"{"slug": "x", "policy": {"read": "on", "write": "auto", "tool": "ask"}}"#)
        #expect(decoded.policy.mode(for: .read) == .ask)
        #expect(decoded.policy.mode(for: .write) == .ask)
        #expect(decoded.policy.mode(for: .tool) == .on)
        #expect(decoded.policy.mode(for: .never) == nil)
    }

    @Test func menusOfferOnlyValidModes() {
        #expect(ConnectorToolGroup.read.modes == [.auto, .ask, .off])
        #expect(ConnectorToolGroup.write.modes == [.ask, .off])
        #expect(ConnectorToolGroup.tool.modes == [.on, .off])
        #expect(ConnectorToolGroup.never.modes.isEmpty)
    }

    @Test func catalogRowKeepsDescriptionAndOnlyWebSources() throws {
        let row = try JSONValue.object([
            "slug": "linear", "name": "Linear", "method": "mcp_oauth", "status": "connected",
            "description": "  Search and update issues.  ", "source": "https://linear.app/docs",
        ]).decoded(as: PalCatalogEntry.self)
        #expect(row.description == "Search and update issues.")
        #expect(row.source == URL(string: "https://linear.app/docs"))
        for unsafe in ["javascript:alert(1)", "file:///etc/passwd", "not a url", ""] {
            let bad = try JSONValue.object(["slug": "a", "name": "A", "method": "none", "status": "connected", "source": .string(unsafe)])
                .decoded(as: PalCatalogEntry.self)
            #expect(bad.source == nil)
        }
        let old = try JSONValue.object(["slug": "a", "name": "A", "method": "none", "status": "connected"]).decoded(as: PalCatalogEntry.self)
        #expect(old.description.isEmpty && old.source == nil)
    }
}

@Suite("Connector details service")
struct ConnectorDetailsServiceTests {
    @Test func detailsCallsTheGatewayWithTheSlugAndProfile() async throws {
        let rpc = CustomRPC(["connectors.details": { _ in try JSONDecoder().decode(JSONValue.self, from: Data(groupedJSON.utf8)) }])
        let loaded = try await service(rpc, profile: "bot-a").details(slug: "upwork")
        #expect(loaded?.tools.count == 4)
        let sent = try #require(rpc.params("connectors.details").first)
        #expect(sent["slug"]?.stringValue == "upwork")
        #expect(sent["profile"]?.stringValue == "bot-a")
    }

    @Test func gatewayWithoutTheMethodGivesNoDetails() async throws {
        let loaded = try await service(CustomRPC([:])).details(slug: "upwork")
        #expect(loaded == nil)
    }

    @Test func otherGatewayErrorsPropagate() async {
        let rpc = CustomRPC(["connectors.details": rpcFailure(5000, reason: "internal")])
        await #expect(throws: ConnectAppsError.self) { _ = try await service(rpc).details(slug: "upwork") }
    }

    @Test func malformedPayloadIsAFailureNotEmptyDetails() async {
        let rpc = CustomRPC(["connectors.details": { _ in ["slug": "upwork", "tools": "nope"] }])
        await #expect(throws: ConnectAppsError.self) { _ = try await service(rpc).details(slug: "upwork") }
    }

    @Test func setPolicySendsGroupAndModeAndReturnsTheStoredPolicy() async throws {
        let rpc = CustomRPC(["connectors.details.policy.set": { _ in ["ok": true, "policy": ["read": "off", "write": "ask"]] }])
        let policy = try await service(rpc, profile: "bot-a").setPolicy(slug: "upwork", group: .read, mode: .off)
        #expect(policy.mode(for: .read) == .off)
        let sent = try #require(rpc.params("connectors.details.policy.set").first)
        #expect(sent["slug"]?.stringValue == "upwork")
        #expect(sent["group"]?.stringValue == "read")
        #expect(sent["mode"]?.stringValue == "off")
        #expect(sent["profile"]?.stringValue == "bot-a")
    }

    @Test func setPolicyRefusesInvalidCombinationsWithoutCalling() async {
        let rpc = CustomRPC(["connectors.details.policy.set": { _ in ["ok": true, "policy": [:]] }])
        for (group, mode) in [(ConnectorToolGroup.write, ConnectorPolicyMode.auto), (.never, .off), (.tool, .ask), (.read, .on)] {
            await #expect(throws: ConnectAppsError.self) { _ = try await service(rpc).setPolicy(slug: "u", group: group, mode: mode) }
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func setPolicyRejectedByTheGatewayThrowsAFault() async {
        let rpc = CustomRPC(["connectors.details.policy.set": rpcFailure(4000, reason: "invalid_params")])
        await #expect(throws: ConnectAppsError.self) { _ = try await service(rpc).setPolicy(slug: "u", group: .read, mode: .off) }
    }

    @Test func setPolicyWithoutAPolicyInTheReplyThrows() async {
        let rpc = CustomRPC(["connectors.details.policy.set": { _ in ["ok": true] }])
        await #expect(throws: ConnectAppsError.self) { _ = try await service(rpc).setPolicy(slug: "u", group: .read, mode: .off) }
    }
}

@Suite("Connector details layout")
struct ConnectorDetailsLayoutTests {
    @Test func groupedSectionsFollowReadsWritesNeverWithCountsAndModes() throws {
        let sections = ConnectorDetailsLayout.toolSections(try details(groupedJSON))
        #expect(sections.map(\.group) == [.read, .write, .never])
        #expect(sections.map(\.count) == [2, 1, 1])
        #expect(sections.map(\.mode) == [.auto, .ask, nil])
        #expect(sections.map(\.title) == ["Reads", "Writes", "Never allowed"])
        #expect(sections[2].options.isEmpty)
        #expect(sections[0].options == [.auto, .ask, .off])
    }

    @Test func ungroupedGivesOneToolsSection() throws {
        let sections = ConnectorDetailsLayout.toolSections(try details(ungroupedJSON))
        #expect(sections.map(\.title) == ["Tools"])
        #expect(sections[0].mode == .on)
        #expect(sections[0].options == [.on, .off])
    }

    @Test func emptyGroupsAndUnknownToolsProduceNoSection() throws {
        let unknown = try details(#"{"slug": "x", "grouped": true, "tools_known": false, "tools": [{"name": "a", "group": "read"}]}"#)
        #expect(ConnectorDetailsLayout.toolSections(unknown).isEmpty)
        let onlyReads = try details(#"{"slug": "x", "grouped": true, "tools_known": true, "tools": [{"name": "a", "group": "read"}]}"#)
        #expect(ConnectorDetailsLayout.toolSections(onlyReads).map(\.group) == [.read])
    }

    @Test func collapsedShowsFiveRowsThenShowAll() {
        let tools = (0..<23).map { ConnectorDetailTool(name: "t\($0)", title: "T\($0)", description: "", group: .read) }
        #expect(ConnectorDetailsLayout.visible(tools, showingAll: false).count == 5)
        #expect(ConnectorDetailsLayout.visible(tools, showingAll: true).count == 23)
        #expect(ConnectorDetailsLayout.hasMore(tools))
        #expect(!ConnectorDetailsLayout.hasMore(Array(tools.prefix(5))))
    }

    @Test func policyLabelsUseTheMockupWords() {
        #expect(ConnectorPolicyMode.auto.title == "Runs without asking")
        #expect(ConnectorPolicyMode.ask.title == "Ask first")
        #expect(ConnectorPolicyMode.off.title == "Off")
        #expect(ConnectorPolicyMode.on.title == "On")
    }

    @Test func informationShowsMethodCategoryVerifiedSourceAndHostOnly() throws {
        let app = try catalogEntry(source: "https://linear.app/docs/mcp")
        let rows = ConnectorInformation.rows(for: app)
        #expect(rows.map(\.kind) == [.signInMethod, .category, .verified, .source, .address])
        #expect(rows.first { $0.kind == .address }?.value == "mcp.linear.app")
        #expect(rows.first { $0.kind == .signInMethod }?.value == "Browser sign-in")
        #expect(rows.first { $0.kind == .verified }?.value == "Yes")
        #expect(rows.first { $0.kind == .source }?.value == "Setup guide")
        #expect(rows.first { $0.kind == .source }?.link == URL(string: "https://linear.app/docs/mcp"))
        #expect(!rows.contains { $0.value.contains("pw") || $0.value.contains("token") || $0.value.contains("/sse") })
    }

    @Test func informationHidesRowsWithNoData() throws {
        let app = try catalogEntry(mcp: "", method: .apiKey, verified: false, category: "")
        let rows = ConnectorInformation.rows(for: app)
        #expect(rows.map(\.kind) == [.signInMethod, .verified])
        #expect(rows.first { $0.kind == .verified }?.value == "No")
        #expect(rows.first { $0.kind == .signInMethod }?.value == "API key")
    }
}

@Suite("Connect Apps row account line")
struct ConnectorAccountLineTests {
    private func accounts(_ names: [(String, ConnectorAccountState)]) -> [ConnectorAccount] {
        names.map { ConnectorAccount(name: $0.0, state: $0.1) }
    }

    @Test func singleDefaultAccountShowsNoLine() throws {
        #expect(try catalogEntry(accounts: accounts([("default", .connected)])).accountLine == nil)
    }

    @Test func singleNamedAccountShowsItsName() throws {
        #expect(try catalogEntry(accounts: accounts([("work", .connected)])).accountLine == "work")
    }

    @Test func severalAccountsListEveryName() throws {
        let app = try catalogEntry(accounts: accounts([("work", .connected), ("personal", .needsReconnect)]))
        #expect(app.accountLine == "work, personal")
    }

    @Test func noAccountsShowsNoLine() throws {
        #expect(try catalogEntry().accountLine == nil)
    }

    @Test func connectedRowOfADetailsAppUsesTheLineAndStaysQuietWithout() throws {
        let linear = try catalogEntry(accounts: accounts([("default", .connected)]))
        #expect(ConnectListRow(app: linear, state: .connected).summary.isEmpty)
        let github = try catalogEntry(accounts: accounts([("work", .connected)]))
        #expect(ConnectListRow(app: github, state: .connected).summary == "work")
    }

    @Test func needsSignInRowKeepsTheReasonWhenThereIsNoNamedAccount() throws {
        let app = try catalogEntry(accounts: accounts([("default", .needsReconnect)]))
        let row = ConnectListRow(app: app, state: .needsAttention(reason: "Sign-in expired"))
        #expect(row.summary == "Sign-in expired" && row.hasProblem)
        let named = try catalogEntry(accounts: accounts([("work", .connected), ("personal", .needsReconnect)]))
        #expect(ConnectListRow(app: named, state: .needsAttention(reason: "Sign-in expired")).summary == "work, personal")
    }

    @Test func detailsOpenOnlyForCatalogConnectors() throws {
        #expect(try catalogEntry().opensDetails)
        let mcp = ConnectApp(id: "m", name: "M", summary: "", category: "", source: .mcp(name: "m", requires: []), state: .connected)
        #expect(!mcp.opensDetails)
        let bot = try JSONValue.object(["slug": "slack", "name": "Slack", "method": "bot_app", "status": "connected"]).decoded(as: PalCatalogEntry.self)
        #expect(!ConnectCatalog.make(catalog: [bot], mcp: []).apps[0].opensDetails)
    }
}
