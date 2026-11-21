import Foundation
import PalConnect
import PalProtocol
import Testing

private func decode(_ json: String) throws -> PalCatalogEntry {
    try JSONDecoder().decode(PalCatalogEntry.self, from: Data(json.utf8))
}

private func row(_ extra: String = "", status: String = "connected") -> String {
    #"{"slug":"linear","name":"Linear","method":"mcp_oauth","status":"\#(status)","mcp_url":"https://mcp.linear.app/mcp"\#(extra)}"#
}

private func accountsJSON(_ rows: String...) -> String {
    #","multi_account":true,"accounts":[\#(rows.joined(separator: ","))]"#
}

private func account(_ name: String, _ state: ConnectorAccountState, reason: String? = nil) -> ConnectorAccount {
    ConnectorAccount(name: name, state: state, reason: reason)
}

private func entry(_ accounts: [ConnectorAccount], status: PalCatalogEntry.Status = .notConnected, multi: Bool = true) -> PalCatalogEntry {
    PalCatalogEntry(
        slug: "slack", name: "Slack", category: "Communication", method: .mcpOAuth, verified: true,
        mcpURL: URL(string: "https://mcp.example.com/mcp"), status: status, multiAccount: multi, accounts: accounts
    )
}

private func app(_ accounts: [ConnectorAccount], status: PalCatalogEntry.Status = .notConnected, multi: Bool = true) -> ConnectApp {
    ConnectCatalog.make(catalog: [entry(accounts, status: status, multi: multi)], mcp: []).apps[0]
}

@Suite("Connector accounts on the catalog wire")
struct ConnectorAccountWireTests {
    @Test func aMultiAccountRowDecodesItsAccounts() throws {
        let reason = "Sign in again: Linear stopped accepting the saved sign-in"
        let decoded = try decode(row(accountsJSON(
            #"{"name":"default","status":"connected","reason":null}"#,
            #"{"name":"work","status":"needs_reconnect","reason":"\#(reason)"}"#
        )))
        #expect(decoded.multiAccount)
        #expect(decoded.accounts == [
            account("default", .connected),
            account("work", .needsReconnect, reason: reason),
        ])
    }

    @Test func anOlderGatewayRowStillDecodesWithNoAccounts() throws {
        let decoded = try decode(row())
        #expect(!decoded.multiAccount)
        #expect(decoded.accounts.isEmpty)
        #expect(decoded.status == .connected)
    }

    @Test func aMultiAccountRowWithoutAnAccountsListDecodesEmpty() throws {
        let decoded = try decode(row(#","multi_account":true"#, status: "not_connected"))
        #expect(decoded.multiAccount)
        #expect(decoded.accounts.isEmpty)
    }

    @Test func anAccountThatCannotBeReadIsDroppedNotTheRow() throws {
        let decoded = try decode(row(accountsJSON(
            #"{"name":"default","status":"connected"}"#, #"{"status":"connected"}"#, #"{"name":"","status":"connected"}"#,
            #"{"name":"Bad Name","status":"connected"}"#, #""junk""#, #"{"name":"work","status":"from_the_future"}"#
        )))
        #expect(decoded.accounts == [account("default", .connected), account("work", .notConnected)])
    }

    @Test func aMissingReasonIsNilAndABlankOneIsDropped() throws {
        let decoded = try decode(row(accountsJSON(
            #"{"name":"a","status":"needs_reconnect"}"#, #"{"name":"b","status":"needs_reconnect","reason":"  "}"#
        )))
        #expect(decoded.accounts.map(\.reason) == [nil, nil])
    }

    @Test func theCatalogCallCarriesAccountsToTheApp() async throws {
        let wire = row(accountsJSON(#"{"name":"default","status":"connected"}"#))
        let rpc = CustomRPC([
            "connectors.catalog": { _ in
                ["connectors": [try JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))]]
            },
            "mcp.catalog": { _ in ["servers": []] },
        ])
        let catalog = try await customService(rpc).load()
        let linear = try #require(catalog.apps.first)
        #expect(linear.accounts == [account("default", .connected)])
        #expect(linear.supportsAccounts)
    }
}

@Suite("Connector account state")
struct ConnectorAccountStateTests {
    @Test func anyConnectedAccountMakesTheRowConnected() {
        #expect(ConnectorAccountState.aggregate([account("a", .needsReconnect), account("b", .connected)]) == .connected)
        #expect(ConnectorAccountState.aggregate([account("a", .notConnected), account("b", .connected)]) == .connected)
        #expect(ConnectorAccountState.aggregate([account("a", .connected)]) == .connected)
    }

    @Test func noneConnectedAndOneNeedingReconnectNeedsReconnect() {
        #expect(ConnectorAccountState.aggregate([account("a", .needsReconnect), account("b", .notConnected)]) == .needsAuthorization)
        #expect(ConnectorAccountState.aggregate([account("a", .needsReconnect)]) == .needsAuthorization)
    }

    @Test func otherwiseTheRowIsNotConnected() {
        #expect(ConnectorAccountState.aggregate([account("a", .notConnected)]) == .disconnected)
        #expect(ConnectorAccountState.aggregate([]) == nil)
    }

    @Test func theRowStateFollowsTheAccountsForAMultiAccountConnector() {
        #expect(app([account("a", .needsReconnect), account("b", .connected)]).state == .connected)
        #expect(app([account("a", .needsReconnect), account("b", .notConnected)]).state == .needsAuthorization)
        #expect(app([account("a", .notConnected)], status: .connected).state == .disconnected)
        #expect(app([], status: .notConnected).state == .disconnected)
    }

    @Test func aRowWithoutAccountsFollowsItsStatusAsBefore() {
        #expect(app([], status: .connected, multi: false).state == .connected)
        #expect(app([], status: .needsReconnect, multi: false).state == .needsAuthorization)
        #expect(app([account("a", .notConnected)], status: .connected, multi: false).state == .connected)
    }

    @Test func aSetupRequirementStillWins() {
        #expect(app([], status: .needsSetup).state == .needsSetup)
    }

    @Test func eachAccountHasItsOwnRowState() {
        #expect(account("a", .connected).rowState() == .connected)
        #expect(account("a", .notConnected).rowState() == .connect)
        #expect(account("a", .needsReconnect).rowState() == .needsAttention(reason: ConnectRowState.expiredSignIn))
        #expect(account("a", .needsReconnect, reason: "Linear refused it.").rowState() == .needsAttention(reason: "Linear refused it."))
        #expect(account("a", .connected).rowState(isBusy: true) == .waiting(reason: String(localized: "Working…")))
    }

    @Test func theRowReadsTheAggregateOnly() {
        let mixed = app([account("work", .needsReconnect, reason: "Nope"), account("default", .connected)])
        let input = ConnectRowInput(app: mixed)
        #expect(ConnectRowState.resolve(input) == .connected)
        let listRow = ConnectListRow(app: mixed, state: ConnectRowState.resolve(input))
        #expect(!listRow.hasProblem)
        #expect(listRow.summary == String(localized: "Connected"))
        let sections = ConnectListLayout.sections(rows: [listRow], categories: ["Communication"])
        #expect(sections.map(\.kind) == [.connected])
    }

    @Test func connectedServicesReadsTheAggregateOnly() {
        let someConnected = ConnectCatalog(apps: [app([account("a", .needsReconnect), account("b", .connected)])])
        let noneConnected = ConnectCatalog(apps: [app([account("a", .needsReconnect), account("b", .notConnected)])])
        #expect(ConnectedServices(catalog: someConnected).isConnected(.slack))
        #expect(!ConnectedServices(catalog: noneConnected).isConnected(.slack))
    }

    @Test func accountNamesAndAccountLookupAreAvailableOnTheApp() {
        let multi = app([account("default", .connected), account("work", .needsReconnect)])
        #expect(multi.accountNames == ["default", "work"])
        #expect(multi.account(named: "work")?.state == .needsReconnect)
        #expect(multi.account(named: "nope") == nil)
        #expect(multi.accountsNeedingReconnect.map(\.name) == ["work"])
        let single = app([], multi: false)
        #expect(!single.supportsAccounts)
        #expect(single.accountNames.isEmpty)
    }
}
