import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let fakeSecret = "fake-token-do-not-use"
private let figmaRedirect = "http://localhost:27890/callback"
private let googleRedirect = "https://pal.example.test/webapp/google-install/callback"
private let consentTiming = ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3, consentAttempts: 6)

private func figma(_ status: PalCatalogEntry.Status = .notConnected) -> PalCatalogEntry {
    catalogEntry("figma", "Figma", "Other", method: .oauthClient, status: status, url: "https://mcp.figma.com/mcp")
}

private func slack(_ status: PalCatalogEntry.Status = .needsSetup) -> PalCatalogEntry {
    catalogEntry("slack", "Slack", "Other", method: .oauthClient, status: status, url: "https://mcp.slack.com/mcp")
}

private func google(_ status: PalCatalogEntry.Status = .notConnected) -> PalCatalogEntry {
    catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .oauthClient, status: status, url: nil)
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

private func figmaConnectReply(_ params: JSONValue) -> JSONValue {
    let encoded = (params["client_redirect_uri"]?.stringValue ?? figmaRedirect).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    let link = "https://www.figma.com/oauth?response_type=code&state=st-1&redirect_uri=\(encoded)"
    return ["slug": "figma", "auth_url": .string(link), "session_id": "s1"]
}

private func figmaGateway(callback: JSONValue = ["ok": true], poll: JSONValue = ["status": "approved"]) -> CustomRPC {
    CustomRPC([
        "connectors.oauth_client.setup": setupReply("figma", redirect: figmaRedirect),
        "connectors.oauth_client.connect": figmaConnectReply,
        "connectors.oauth_client.remove": { _ in ["slug": "figma", "removed": true] },
        "mcp.servers.oauth.callback": { _ in callback },
        "mcp.servers.oauth.poll": { _ in poll },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

private struct LocalhostRedirectBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "redirect_uri" })?.value, var back = URLComponents(string: target),
              let port = back.port
        else { return }
        back.queryItems = [URLQueryItem(name: "code", value: fakeSecret), URLQueryItem(name: "state", value: "st-1")]
        back.host = "127.0.0.1"
        var request = URLRequest(url: back.url!)
        request.setValue("localhost:\(port)", forHTTPHeaderField: "Host")
        _ = try await URLSession.shared.data(for: request)
        try await Task.sleep(for: .seconds(10))
    }

    func dismiss() async {}
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
            ["slug": "google-workspace", "auth_url": "https://accounts.google.com/o/oauth2/v2/auth?state=st-1", "session_id": .null]
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
        let rpc = CustomRPC(["connectors.oauth_client.setup": setupReply("figma", configured: false, redirect: figmaRedirect)])
        let setup = try await service(rpc, profile: "alpha").oauthClientSetup(slug: "figma")
        let console = URL(string: "https://console.example.test/apps")
        #expect(setup == OAuthClientSetup(slug: "figma", configured: false, consoleURL: console, redirectURL: figmaRedirect))
        let sent = try #require(rpc.params("connectors.oauth_client.setup").first)
        #expect(sent["slug"]?.stringValue == "figma" && sent["profile"]?.stringValue == "alpha")
    }

    @Test func aGatewayWithoutAPublicAddressLeavesTheRedirectUrlEmpty() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.setup": setupReply("google-workspace", configured: false, redirect: nil)])
        #expect(try await service(rpc).oauthClientSetup(slug: "google-workspace").redirectURL == nil)
    }

    @Test func saveWritesBothValuesToTheVaultThenSendsOnlyTheItemIds() async throws {
        let issued = CallCounter()
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": .string("item-\(issued.next())")] },
            "connectors.oauth_client.save": setupReply("figma", redirect: figmaRedirect),
        ])
        let saved = try await service(rpc, profile: "alpha").saveOAuthClient(figma(.needsSetup), clientID: "fake-client-id", clientSecret: fakeSecret)
        #expect(saved.configured)
        #expect(rpc.methods() == ["vault.add", "vault.add", "connectors.oauth_client.save"])
        let writes = rpc.params("vault.add")
        #expect(writes.map { $0["kind"]?.stringValue } == ["api_key", "api_key"])
        #expect(writes.map { $0["secret"]?["api_key"]?.stringValue } == ["fake-client-id", fakeSecret])
        let save = try #require(rpc.params("connectors.oauth_client.save").first)
        #expect(save["client_id_item"]?.stringValue == "item-1" && save["client_secret_item"]?.stringValue == "item-2")
        #expect(save["slug"]?.stringValue == "figma" && save["profile"]?.stringValue == "alpha")
        let wire = try #require(String(bytes: try JSONEncoder().encode(save), encoding: .utf8))
        #expect(!wire.contains(fakeSecret) && !wire.contains("fake-client-id"))
    }

    @Test func aRejectedClientIsMappedAndItsVaultItemsAreRemoved() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-x"] },
            "connectors.oauth_client.save": rpcFailure(4000, reason: "INVALID_CLIENT"),
            "vault.remove": { _ in ["ok": true] },
        ])
        let failure = await thrown { _ = try await service(rpc).saveOAuthClient(figma(.needsSetup), clientID: "bad", clientSecret: fakeSecret) }
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
            _ = try await service(rpc).saveOAuthClient(figma(.needsSetup), clientID: "id", clientSecret: fakeSecret)
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
            _ = try await service(rpc).saveOAuthClient(figma(.needsSetup), clientID: "id", clientSecret: fakeSecret)
        }
        #expect(rpc.methods() == ["vault.add", "vault.add", "vault.remove"])
        #expect(rpc.params("vault.remove").first?["id"]?.stringValue == "item-1")
    }
}

@Suite("Owner OAuth client connect")
struct OAuthClientConnectTests {
    @Test func aRowThatNeedsSetupNeverReachesTheGateway() async {
        let rpc = CustomRPC([:])
        for entry in [figma(.needsSetup), slack()] {
            await #expect(throws: ConnectAppsError.oauthClient(.needsSetup)) { try await service(rpc).connect(app(entry)) }
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func figmaOnTheMacBindsLocalhostAndRelaysTheRedirectThroughTheMcpRelay() async throws {
        let rpc = figmaGateway()
        try await service(rpc, browser: LocalhostRedirectBrowser()).connect(app(figma()))
        #expect(rpc.methods() == [
            "connectors.oauth_client.setup", "connectors.oauth_client.connect", "mcp.servers.oauth.callback", "mcp.servers.oauth.poll",
        ])
        #expect(rpc.params("connectors.oauth_client.connect").first?["client_redirect_uri"]?.stringValue == figmaRedirect)
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["name"]?.stringValue == "figma" && relayed["session_id"]?.stringValue == "s1")
        #expect(relayed["code"]?.stringValue == fakeSecret && relayed["state"]?.stringValue == "st-1")
        #expect(rpc.params("mcp.servers.oauth.poll").first?["session_id"]?.stringValue == "s1")
    }

    @Test func figmaOnIPhoneReturnsAPasteSessionThatRelaysThePastedAddress() async throws {
        let rpc = figmaGateway()
        let outcome = try await service(rpc).connectOAuthClient(figma(.needsReconnect), route: .pasteAddress)
        guard case .paste(let session) = outcome else { Issue.record("expected a paste session"); return }
        #expect(session.authorizeURL.host() == "www.figma.com")
        #expect(await session.submit("\(figmaRedirect)?code=\(fakeSecret)&state=st-1") == .signedIn)
        #expect(rpc.methods() == [
            "connectors.oauth_client.setup", "connectors.oauth_client.connect", "mcp.servers.oauth.callback", "mcp.servers.oauth.poll",
        ])
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["name"]?.stringValue == "figma" && relayed["code"]?.stringValue == fakeSecret)
    }

    @Test func aDeniedPasteSignInForAFreshRowRemovesTheSignInAgainButKeepsTheClient() async throws {
        let rpc = figmaGateway(callback: ["ok": false, "error_message": "access_denied"])
        guard case .paste(let session) = try await service(rpc).connectOAuthClient(figma(.notConnected), route: .pasteAddress) else {
            Issue.record("expected a paste session")
            return
        }
        #expect(await session.submit("\(figmaRedirect)?code=\(fakeSecret)&state=st-1") == .failed(McpSignInFailure.denied.reason))
        #expect(rpc.methods().suffix(2) == ["mcp.servers.oauth.cancel", "connectors.oauth_client.remove"])
        #expect(!rpc.methods().contains("connectors.oauth_client.save"))
    }

    @Test func aDeniedPasteSignInForAnExistingSignInKeepsIt() async throws {
        let rpc = figmaGateway(callback: ["ok": false, "error_message": "access_denied"])
        guard case .paste(let session) = try await service(rpc).connectOAuthClient(figma(.needsReconnect), route: .pasteAddress) else {
            Issue.record("expected a paste session")
            return
        }
        _ = await session.submit("\(figmaRedirect)?code=\(fakeSecret)&state=st-1")
        #expect(!rpc.methods().contains("connectors.oauth_client.remove"))
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

    @Test func googleOnIPhoneUsesTheSameConsentFlowWithoutAPasteStep() async throws {
        let rpc = googleGateway(statuses: [.connected])
        guard case .connected = try await service(rpc, browser: BlockingBrowser()).connectOAuthClient(google(), route: .pasteAddress) else {
            Issue.record("expected a finished sign-in")
            return
        }
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
        let rpc = CustomRPC(["connectors.oauth_client.remove": { _ in ["slug": "figma", "removed": true] }])
        try await service(rpc, profile: "alpha").disconnect(app(figma(.connected)))
        #expect(rpc.methods() == ["connectors.oauth_client.remove"])
        let sent = try #require(rpc.params("connectors.oauth_client.remove").first)
        #expect(sent["slug"]?.stringValue == "figma" && sent["profile"]?.stringValue == "alpha")
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
        for (status, state) in expectations { #expect(app(figma(status)).state == state) }
    }

    @Test func aRowThatNeedsSetupSaysSoInPlainWordsAndOtherRowsKeepTheirOwnCopy() {
        let acme = catalogEntry("acme", "Acme", "Developer", method: .mcpOAuth, status: .needsSetup)
        let apps = ConnectCatalog.make(catalog: [figma(.needsSetup), acme], mcp: []).apps
        #expect(apps.first { $0.id == "connector:figma" }?.summary == "Save your OAuth client once to connect.")
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
            "connectors.catalog": { _ in ["connectors": [["slug": "figma", "name": "Figma", "method": "oauth_client", "status": "connected"]]] },
            "mcp.catalog": { _ in ["servers": []] },
        ])
        let loaded = try await service(rpc).load()
        #expect(loaded.apps.map(\.id) == ["connector:figma"])
        #expect(!rpc.methods().contains("google_workspace.status"))
    }

    @Test func theGuideNamesTheConsoleStepsForGoogle() {
        let googleSteps = OAuthClientGuide.steps(slug: "google-workspace", appName: "Google Workspace").joined(separator: " ")
        #expect(googleSteps.contains("Web application") && googleSteps.contains("Authorized redirect URI") && googleSteps.contains("test user"))
    }
}

@Suite("Loopback listener on a fixed port")
struct LoopbackFixedPortTests {
    @Test func bindsTheRequestedPortAndAnswersTheLocalhostHostName() async throws {
        let port = UInt16.random(in: 40_000...48_000)
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10), fixedPort: port, redirectHost: "localhost")
        defer { listener.cancel() }
        #expect(listener.port == port)
        #expect(listener.redirectURI == "http://localhost:\(port)/callback")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!)
        request.setValue("localhost:\(port)", forHTTPHeaderField: "Host")
        async let parameters = listener.awaitCallback()
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await parameters == ["code": "abc", "state": "xyz"])
    }
}
