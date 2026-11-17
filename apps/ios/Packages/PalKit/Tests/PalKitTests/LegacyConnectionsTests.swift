import Foundation
import PalConnect
import PalProtocol
import Testing

private func legacyItem(
    _ slug: String, catalogID: String? = nil, source: LegacyConnectorItem.Source = .portal,
    method: PalCatalogEntry.Method? = nil, state: LegacyConnectorItem.State = .needsReconnect
) -> LegacyConnectorItem {
    LegacyConnectorItem(catalogID: catalogID, name: slug.capitalized, legacySlug: slug, source: source, method: method, state: state)
}

private func legacyCatalog(_ entries: PalCatalogEntry...) -> ConnectCatalog {
    ConnectCatalog.make(catalog: entries, mcp: [])
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "legacy-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Suite("Legacy connections")
struct LegacyConnectionsTests {
    private let wiki = catalogEntry("deepwiki", "Deepwiki", "Other", method: .none)

    @Test func decodesTheGatewayResultAndToleratesUnknownValues() throws {
        let value: JSONValue = [
            "source_readable": true,
            "items": [
                ["catalog_id": "deepwiki", "name": "Deepwiki", "legacy_slug": "deepwiki", "legacy_source": "portal", "method": "none",
                 "state": "needs_reconnect", "last_seen": 1_760_000_000],
                ["name": "Odd", "legacy_slug": "odd", "legacy_source": "carrier-pigeon", "state": "unmapped"],
            ],
        ]
        let result = try value.decoded(as: LegacyConnectionsResult.self)
        #expect(result.sourceReadable)
        #expect(result.items.map(\.legacySlug) == ["deepwiki", "odd"])
        #expect(result.items[0].method == PalCatalogEntry.Method.none)
        #expect(result.items[0].lastSeen == 1_760_000_000)
        #expect(result.items[1].source == .unknown)
        #expect(result.items[1].method == nil)
    }

    @Test func anEmptyUnreadableResultIsReportedAsUnreadable() throws {
        let value: JSONValue = ["source_readable": false, "items": []]
        #expect(try value.decoded(as: LegacyConnectionsResult.self).isUnreadable)
        #expect(!LegacyConnectionsResult(sourceReadable: true).isUnreadable)
    }

    @Test func aConnectedCatalogRowHidesTheLegacyRow() {
        let result = LegacyConnectionsResult(sourceReadable: true, items: [legacyItem("deepwiki", catalogID: "deepwiki", method: PalCatalogEntry.Method.none)])
        let idle = legacyCatalog(wiki)
        #expect(LegacyReconnect.rows(result, catalog: idle, dismissed: []).map(\.id) == ["deepwiki"])
        var connected = wiki
        connected.status = .connected
        #expect(LegacyReconnect.rows(result, catalog: legacyCatalog(connected), dismissed: []).isEmpty)
    }

    @Test func aDismissedSlugHidesTheLegacyRow() {
        let result = LegacyConnectionsResult(sourceReadable: true, items: [
            legacyItem("deepwiki", catalogID: "deepwiki", method: PalCatalogEntry.Method.none),
            legacyItem("odd"),
        ])
        let rows = LegacyReconnect.rows(result, catalog: legacyCatalog(wiki), dismissed: ["deepwiki"])
        #expect(rows.map(\.id) == ["odd"])
    }

    @Test func anUnmappedItemIsKeptWithNoReconnectAndTheNoOptionText() throws {
        let result = LegacyConnectionsResult(sourceReadable: true, items: [legacyItem("odd", state: .unmapped)])
        let row = try #require(LegacyReconnect.rows(result, catalog: legacyCatalog(wiki), dismissed: []).first)
        #expect(row.route == .noDirectOption)
        #expect(row.route.actionTitle == nil)
        #expect(row.summary.contains("No direct option yet"))
    }

    @Test func routingFollowsTheMethodTable() {
        let oauth = catalogEntry("slack", "Slack", "Communication", method: .mcpOAuth)
        let key = catalogEntry("github", "GitHub", "Developer", method: .apiKey)
        let client = catalogEntry("acme", "Acme", "Developer", method: .oauthClient, status: .needsSetup, url: nil)
        let google = catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .native, url: nil)
        let catalog = legacyCatalog(wiki, oauth, key, client, google)
        func route(_ slug: String, _ method: PalCatalogEntry.Method) -> LegacyReconnectRoute {
            LegacyReconnect.route(for: legacyItem(slug, catalogID: slug, method: method), in: catalog)
        }
        #expect(route("deepwiki", .none) == .connect(appID: "connector:deepwiki"))
        #expect(route("slack", .mcpOAuth) == .connect(appID: "connector:slack"))
        #expect(route("github", .apiKey) == .connect(appID: "connector:github"))
        #expect(route("acme", .oauthClient) == .needsSetup)
        #expect(route("missing", .none) == .noDirectOption)
        #expect(route("mystery", .native) == .noDirectOption)
    }

    @Test func aConnectedOAuthClientGoogleRowHidesTheLegacyGoogleRow() {
        let item = legacyItem("google-workspace", catalogID: "google-workspace", method: .oauthClient)
        let result = LegacyConnectionsResult(sourceReadable: true, items: [item])
        let google = catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .oauthClient, status: .connected, url: nil)
        #expect(LegacyReconnect.rows(result, catalog: legacyCatalog(google), dismissed: []).isEmpty)
    }

    @Test func nativeGoogleRoutesToItsSignInWhenTheCatalogHasIt() {
        let google = catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .native, url: nil)
        let catalog = ConnectCatalog.make(catalog: [google], mcp: [], google: GoogleWorkspaceStatus(state: .needsSignIn))
        let item = legacyItem("google-workspace", catalogID: "google-workspace", method: .native)
        #expect(LegacyReconnect.route(for: item, in: catalog) == .signIn(appID: GoogleWorkspaceCatalog.appID))
    }

    @Test func theSummaryNamesTheOldSource() {
        #expect(LegacyReconnectText.summary(source: .portal, route: .connect(appID: "x")).contains("Nous Portal"))
        #expect(LegacyReconnectText.summary(source: .composio, route: .connect(appID: "x")).contains("Composio"))
        #expect(LegacyReconnectText.summary(source: .portal, route: .needsSetup).contains("Needs setup"))
    }

    @Test func dismissalsPersistPerProfileOnTheSameDevice() {
        let defaults = isolatedDefaults()
        let first = UserDefaultsLegacyDismissals(defaults: defaults)
        first.dismiss("deepwiki", profile: "alpha")
        first.dismiss("slack", profile: "alpha")
        let reopened = UserDefaultsLegacyDismissals(defaults: defaults)
        #expect(reopened.dismissed(profile: "alpha") == ["deepwiki", "slack"])
        #expect(reopened.dismissed(profile: "beta").isEmpty)
        #expect(reopened.dismissed(profile: nil).isEmpty)
    }

    @Test func theServiceReadsConnectorsLegacyScopedToTheProfile() async throws {
        let rpc = CustomRPC([
            "connectors.legacy": { _ in ["source_readable": true, "items": [["name": "Deepwiki", "legacy_slug": "deepwiki", "state": "needs_reconnect"]]] },
        ])
        let result = try await customService(rpc, profile: "alpha").legacyConnections()
        #expect(result.items.map(\.legacySlug) == ["deepwiki"])
        #expect(rpc.params("connectors.legacy").first?["profile"]?.stringValue == "alpha")
    }

    @Test func anRPCFailureOrMalformedAnswerSurfacesAsAFailure() async {
        let missing = CustomRPC([:])
        await #expect(throws: ConnectAppsError.self) { try await customService(missing).legacyConnections() }
        let malformed = CustomRPC(["connectors.legacy": { _ in ["items": "nope"] }])
        await #expect(throws: ConnectAppsError.self) { try await customService(malformed).legacyConnections() }
    }
}
