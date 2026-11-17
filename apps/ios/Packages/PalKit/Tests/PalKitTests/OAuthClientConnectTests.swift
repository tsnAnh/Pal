import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let fakeSecret = "fake-token-do-not-use"
private let googleRedirect = "https://pal.example.test/webapp/google-install/callback"
private let consentTiming = ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3, consentAttempts: 6)

private func google(_ status: PalCatalogEntry.Status = .notConnected) -> PalCatalogEntry {
    catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .oauthClient, status: status, url: nil)
}

private func slack(_ status: PalCatalogEntry.Status = .needsSetup) -> PalCatalogEntry {
    catalogEntry("slack", "Slack", "Other", method: .oauthClient, status: status, url: "https://mcp.slack.com/mcp")
}

private func thrown(_ work: () async throws -> Void) async -> ConnectAppsError? {
    do { try await work(); return nil } catch { return error as? ConnectAppsError }
}

private func app(_ entry: PalCatalogEntry) -> ConnectApp {
    ConnectApp(
        id: "connector:\(entry.slug)", name: entry.name, summary: "", category: entry.category, source: .catalog(entry), state: entry.appState
    )
}

private func setupReply(_ slug: String, configured: Bool = true, redirect: String?) -> CustomRPC.Reply {
    { _ in
        [
            "slug": .string(slug), "configured": .bool(configured), "console_url": "https://console.example.test/apps",
            "redirect_url": redirect.map(JSONValue.string) ?? JSONValue.null,
        ]
    }
}

private func catalogReplies(_ statuses: [PalCatalogEntry.Status]) -> CustomRPC.Reply {
    let calls = CallCounter()
    return { _ in
        let status = statuses[min(calls.next() - 1, statuses.count - 1)]
        return ["connectors": [["slug": "google-workspace", "name": "Google Workspace", "method": "oauth_client", "status": .string(status.rawValue)]]]
    }
}

private func googleGateway(statuses: [PalCatalogEntry.Status]) -> CustomRPC {
    CustomRPC([
        "connectors.oauth_client.setup": setupReply("google-workspace", redirect: googleRedirect),
        "connectors.oauth_client.connect": { _ in
            ["slug": "google-workspace", "auth_url": "https://accounts.google.com/o/oauth2/v2/auth?state=st-1"]
        },
        "connectors.oauth_client.remove": { _ in ["slug": "google-workspace", "removed": true] },
        "connectors.catalog": catalogReplies(statuses),
    ])
}

private func service(_ rpc: CustomRPC, profile: String? = nil, browser: any AuthorizationBrowser = IdleBrowser()) -> ConnectAppsService {
    ConnectAppsService(rpc: rpc, profile: profile, browser: browser, timing: consentTiming)
}

@Suite("Owner OAuth client setup and save")
struct OAuthClientSetupTests {
    @Test func setupReadsTheConsolePageAndTheRedirectUrlForTheScopedProfile() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.setup": setupReply("google-workspace", configured: false, redirect: googleRedirect)])
        let setup = try await service(rpc, profile: "alpha").oauthClientSetup(slug: "google-workspace")
        let console = URL(string: "https://console.example.test/apps")
        #expect(setup == OAuthClientSetup(slug: "google-workspace", configured: false, consoleURL: console, redirectURL: googleRedirect))
        let sent = try #require(rpc.params("connectors.oauth_client.setup").first)
        #expect(sent["slug"]?.stringValue == "google-workspace" && sent["profile"]?.stringValue == "alpha")
    }

    @Test func aGatewayWithoutAPublicAddressLeavesTheRedirectUrlEmpty() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.setup": setupReply("google-workspace", configured: false, redirect: nil)])
        #expect(try await service(rpc).oauthClientSetup(slug: "google-workspace").redirectURL == nil)
    }

    @Test func saveWritesBothValuesToTheVaultThenSendsOnlyTheItemIds() async throws {
        let issued = CallCounter()
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": .string("item-\(issued.next())")] },
            "connectors.oauth_client.save": setupReply("google-workspace", redirect: googleRedirect),
        ])
        let saved = try await service(rpc, profile: "alpha").saveOAuthClient(google(.needsSetup), clientID: "fake-client-id", clientSecret: fakeSecret)
        #expect(saved.configured)
        #expect(rpc.methods() == ["vault.add", "vault.add", "connectors.oauth_client.save"])
        let writes = rpc.params("vault.add")
        #expect(writes.map { $0["kind"]?.stringValue } == ["api_key", "api_key"])
        #expect(writes.map { $0["secret"]?["api_key"]?.stringValue } == ["fake-client-id", fakeSecret])
        let save = try #require(rpc.params("connectors.oauth_client.save").first)
        #expect(save["client_id_item"]?.stringValue == "item-1" && save["client_secret_item"]?.stringValue == "item-2")
        #expect(save["slug"]?.stringValue == "google-workspace" && save["profile"]?.stringValue == "alpha")
        let wire = try #require(String(bytes: try JSONEncoder().encode(save), encoding: .utf8))
        #expect(!wire.contains(fakeSecret) && !wire.contains("fake-client-id"))
    }

    @Test func aRejectedClientIsMappedAndItsVaultItemsAreRemoved() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-x"] },
            "connectors.oauth_client.save": rpcFailure(4000, reason: "INVALID_CLIENT"),
            "vault.remove": { _ in ["ok": true] },
        ])
        let failure = await thrown { _ = try await service(rpc).saveOAuthClient(google(.needsSetup), clientID: "bad", clientSecret: fakeSecret) }
        #expect(failure?.oauthClientFailure == .invalidClient)
        #expect(failure?.fault?.method == "connectors.oauth_client.save")
        #expect(rpc.methods() == ["vault.add", "vault.add", "connectors.oauth_client.save", "vault.remove", "vault.remove"])
    }

    @Test func aLostAnswerKeepsTheVaultItemsBecauseTheGatewayMayHaveSavedThem() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-x"] },
            "connectors.oauth_client.save": { _ in throw GatewayTransportError.timedOut },
        ])
        await #expect(throws: ConnectAppsError.oauthClient(.unreachable)) {
            _ = try await service(rpc).saveOAuthClient(google(.needsSetup), clientID: "id", clientSecret: fakeSecret)
        }
        #expect(!rpc.methods().contains("vault.remove"))
    }

    @Test func aFailedSecondVaultWriteRemovesTheFirstAndNeverSaves() async throws {
        let writes = CallCounter()
        let rpc = CustomRPC([
            "vault.add": { _ in
                if writes.next() == 2 { throw GatewayTransportError.rpc(RPCError(code: 5000, message: "failed")) }
                return ["id": "item-1"]
            },
            "vault.remove": { _ in ["ok": true] },
        ])
        await #expect(throws: ConnectAppsError.oauthClient(.saveFailed)) {
            _ = try await service(rpc).saveOAuthClient(google(.needsSetup), clientID: "id", clientSecret: fakeSecret)
        }
        #expect(rpc.methods() == ["vault.add", "vault.add", "vault.remove"])
        #expect(rpc.params("vault.remove").first?["id"]?.stringValue == "item-1")
    }
}

@Suite("Owner OAuth client connect")
struct OAuthClientConnectTests {
    @Test func aRowThatNeedsSetupNeverReachesTheGateway() async {
        let rpc = CustomRPC([:])
        for entry in [google(.needsSetup), slack()] {
            await #expect(throws: ConnectAppsError.oauthClient(.needsSetup)) { try await service(rpc).connect(app(entry)) }
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func googleOpensTheConsentPageThenPollsTheCatalogUntilTheRowIsConnected() async throws {
        let rpc = googleGateway(statuses: [.notConnected, .notConnected, .connected])
        let browser = BlockingBrowser()
        try await service(rpc, browser: browser).connect(app(google()))
        #expect(browser.presented.withLock { $0 }.map(\.host) == ["accounts.google.com"])
        #expect(rpc.methods().prefix(2) == ["connectors.oauth_client.setup", "connectors.oauth_client.connect"])
        #expect(rpc.params("connectors.oauth_client.connect").first?["client_redirect_uri"] == nil)
        #expect(rpc.methods().filter { $0 == "connectors.catalog" }.count >= 3)
        #expect(!rpc.methods().contains { $0.hasPrefix("mcp.servers.oauth") })
    }

    @Test func returningWithoutFinishingConsentCancelsAndRemovesAFreshSignIn() async {
        let rpc = googleGateway(statuses: [.notConnected])
        await #expect(throws: ConnectAppsError.cancelled) { try await service(rpc, browser: IdleBrowser()).connect(app(google())) }
        #expect(rpc.methods().last == "connectors.oauth_client.remove")
    }

    @Test func consentThatNeverFinishesExpires() async {
        let rpc = googleGateway(statuses: [.notConnected])
        await #expect(throws: ConnectAppsError.signInFailed(McpSignInFailure.expired.reason)) {
            try await service(rpc, browser: BlockingBrowser()).connect(app(google(.needsReconnect)))
        }
        #expect(!rpc.methods().contains("connectors.oauth_client.remove"))
    }

    @Test func aMissingPublicAddressMapsToTheGuidedStepWithoutSideEffects() async {
        for failure in [rpcFailure(4412, reason: "NEEDS_PUBLIC_URL"), rpcFailure(4412)] {
            let rpc = CustomRPC([
                "connectors.oauth_client.setup": setupReply("google-workspace", redirect: googleRedirect),
                "connectors.oauth_client.connect": failure,
            ])
            let browser = RecordingBrowser()
            let failure = await thrown { try await service(rpc, browser: browser).connect(app(google())) }
            #expect(failure?.oauthClientFailure == .needsPublicURL)
            #expect(rpc.methods() == ["connectors.oauth_client.setup", "connectors.oauth_client.connect"])
            #expect(browser.presented.withLock { $0 }.isEmpty)
        }
    }

    @Test func everyGatewayReasonMapsToItsFailure() {
        for failure in OAuthClientFailure.allCases where failure != .unreachable {
            #expect(OAuthClientFailure.classify(reason: failure.rawValue.lowercased(), code: 4000) == failure)
            #expect(!failure.reason.isEmpty)
        }
        #expect(OAuthClientFailure.classify(reason: nil, code: 5034) == .connectFailed)
        #expect(OAuthClientFailure.classify(reason: nil, code: 4412) == .needsPublicURL)
        #expect(OAuthClientFailure.needsPublicURL.reason == "Set this gateway's public address first.")
    }
}

@Suite("Owner OAuth client remove and catalog rows")
struct OAuthClientCatalogTests {
    @Test func removingARowCallsTheOwnerClientRemoveAndNothingElse() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.remove": { _ in ["slug": "google-workspace", "removed": true] }])
        try await service(rpc, profile: "alpha").disconnect(app(google(.connected)))
        #expect(rpc.methods() == ["connectors.oauth_client.remove"])
        let sent = try #require(rpc.params("connectors.oauth_client.remove").first)
        #expect(sent["slug"]?.stringValue == "google-workspace" && sent["profile"]?.stringValue == "alpha")
    }

    @Test func theGoogleCatalogRowReplacesTheNativeRowAndCarriesItsNotes() throws {
        let row: JSONValue = [
            "slug": "google-workspace", "name": "Google Workspace", "category": "Files and docs", "method": "oauth_client",
            "status": "needs_setup", "notes": " Test users only for now. ",
        ]
        let entry = try row.decoded(as: PalCatalogEntry.self)
        let apps = ConnectCatalog.make(catalog: [entry], mcp: []).apps
        #expect(apps.map(\.id) == ["connector:google-workspace"])
        #expect(apps.first?.summary == "Test users only for now.")
        #expect(apps.first?.state == .needsSetup)
        #expect(apps.first?.oauthClientEntry?.slug == "google-workspace")
    }

    @Test func statesFollowTheCatalogStatus() {
        let expectations: [(PalCatalogEntry.Status, ConnectAppState)] = [
            (.needsSetup, .needsSetup), (.notConnected, .disconnected), (.connected, .connected), (.needsReconnect, .needsAuthorization),
        ]
        for (status, state) in expectations { #expect(app(google(status)).state == state) }
    }

    @Test func aRowThatNeedsSetupSaysSoInPlainWordsAndOtherRowsKeepTheirOwnCopy() {
        let acme = catalogEntry("acme", "Acme", "Developer", method: .mcpOAuth, status: .needsSetup)
        let apps = ConnectCatalog.make(catalog: [google(.needsSetup), slack(), acme], mcp: []).apps
        #expect(apps.first { $0.id == "connector:google-workspace" }?.summary == "Save your OAuth client once to connect.")
        #expect(apps.first { $0.id == "connector:acme" }?.summary == "Needs setup on your Pal before it can connect.")
        #expect(app(catalogEntry("deepwiki", "DeepWiki", "Developer")).oauthClientEntry == nil)
    }

    @Test func aRowTheGatewayCannotSetUpOffersNoSetUpAction() {
        let row = app(slack())
        #expect(row.state == .needsSetup)
        #expect(row.oauthClientEntry == nil)
        #expect(ConnectCatalog.make(catalog: [slack()], mcp: []).apps.first?.summary == "Needs setup on your Pal before it can connect.")
    }

    @Test func aConnectedGoogleCatalogRowCountsAsTheConnectedGoogleService() {
        let services = ConnectedServices(catalog: ConnectCatalog.make(catalog: [google(.connected)], mcp: []))
        #expect(services.isConnected(.google))
        #expect(!ConnectedServices(catalog: ConnectCatalog.make(catalog: [google(.needsReconnect)], mcp: [])).isConnected(.google))
    }

    @Test func loadReadsTheCatalogWithoutTheLegacyGoogleStatusCall() async throws {
        let rpc = CustomRPC([
            "connectors.catalog": { _ in
                ["connectors": [["slug": "google-workspace", "name": "Google Workspace", "method": "oauth_client", "status": "connected"]]]
            },
            "mcp.catalog": { _ in ["servers": []] },
        ])
        let loaded = try await service(rpc).load()
        #expect(loaded.apps.map(\.id) == ["connector:google-workspace"])
        #expect(!rpc.methods().contains("google_workspace.status"))
    }

    @Test func theGuideNamesTheConsoleStepsForGoogle() {
        let googleSteps = OAuthClientGuide.steps(slug: "google-workspace", appName: "Google Workspace").joined(separator: " ")
        #expect(googleSteps.contains("Web application") && googleSteps.contains("Authorized redirect URI") && googleSteps.contains("test user"))
    }
}
