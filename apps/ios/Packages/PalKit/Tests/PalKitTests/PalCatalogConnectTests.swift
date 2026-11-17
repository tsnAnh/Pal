import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Testing

func catalogEntry(
    _ slug: String, _ name: String, _ category: String, method: PalCatalogEntry.Method = .none,
    status: PalCatalogEntry.Status = .notConnected, url: String? = "https://mcp.example.com/\(UUID().uuidString)"
) -> PalCatalogEntry {
    PalCatalogEntry(
        slug: slug, name: name, category: category, icon: "plugin_glyph", method: method, verified: true,
        mcpURL: url.flatMap(URL.init(string:)), status: status
    )
}

private struct CatalogRedirectBrowser: AuthorizationBrowser {
    let code: String

    func present(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "redirect_uri" })?.value, var back = URLComponents(string: target) else { return }
        back.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: "st-1")]
        _ = try await URLSession.shared.data(from: back.url!)
        try await Task.sleep(for: .seconds(10))
    }

    func dismiss() async {}
}

private func oauthGateway(add: CustomRPC.Reply? = nil, poll: JSONValue = ["status": "approved"]) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": add ?? { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.oauth.start": { params in
            let redirect = params["client_redirect_uri"]?.stringValue ?? ""
            let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=\(encoded)"
            return ["session_id": "s1", "auth_url": .string(link)]
        },
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { _ in poll },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

@Suite("Pal catalog connect routing")
struct PalCatalogConnectTests {
    private func app(_ entry: PalCatalogEntry) -> ConnectApp {
        ConnectApp(
            id: "connector:\(entry.slug)", name: entry.name, summary: "", category: entry.category, source: .catalog(entry),
            state: entry.status == .connected ? .connected : .disconnected
        )
    }

    @Test func aNoAuthEntryIsAddedByUrlAndNothingElse() async throws {
        let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }])
        let deepwiki = catalogEntry("deepwiki", "DeepWiki", "Developer", url: "https://mcp.deepwiki.com/mcp")
        try await customService(rpc, profile: "alpha").connect(app(deepwiki))
        #expect(rpc.methods() == ["mcp.servers.add"])
        let sent = try #require(rpc.params("mcp.servers.add").first)
        #expect(sent["name"]?.stringValue == "deepwiki")
        #expect(sent["profile"]?.stringValue == "alpha")
        #expect(sent["config"]?["url"]?.stringValue == "https://mcp.deepwiki.com/mcp")
        #expect(sent["config"]?["transport"]?.stringValue == "http")
    }

    @Test func aNoAuthEntryThatIsAlreadyAddedStillConnects() async throws {
        let rpc = CustomRPC(["mcp.servers.add": { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) }])
        try await customService(rpc).connect(app(catalogEntry("deepwiki", "DeepWiki", "Developer")))
        #expect(rpc.methods() == ["mcp.servers.add"])
    }

    @Test func anOAuthEntryIsAddedThenSignedInThroughTheGatewayRelay() async throws {
        let rpc = oauthGateway()
        let browser = CatalogRedirectBrowser(code: "abc")
        let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, url: "https://mcp.notion.com/mcp")
        let signIn = ConnectAppsService(rpc: rpc, profile: nil, browser: browser, timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3))
        try await signIn.connect(app(notion))
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.oauth.start", "mcp.servers.oauth.callback", "mcp.servers.oauth.poll"])
        #expect(rpc.params("mcp.servers.add").first?["config"]?["url"]?.stringValue == "https://mcp.notion.com/mcp")
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["name"]?.stringValue == "notion" && relayed["code"]?.stringValue == "abc" && relayed["state"]?.stringValue == "st-1")
    }

    @Test func anOAuthEntryThatFailsToSignInIsRemovedAgain() async {
        let rpc = oauthGateway(poll: ["status": "error", "error_message": "access_denied"])
        let browser = CatalogRedirectBrowser(code: "abc")
        let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, url: "https://mcp.notion.com/mcp")
        let signIn = ConnectAppsService(rpc: rpc, profile: nil, browser: browser, timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3))
        await #expect(throws: ConnectAppsError.signInFailed(McpSignInFailure.denied.reason)) { try await signIn.connect(app(notion)) }
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func anOAuthEntryThatWasAlreadyAddedIsKeptWhenSignInFails() async {
        let rpc = oauthGateway(add: { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) }, poll: ["status": "error"])
        let browser = CatalogRedirectBrowser(code: "abc")
        let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, status: .needsReconnect, url: "https://mcp.notion.com/mcp")
        let signIn = ConnectAppsService(rpc: rpc, profile: nil, browser: browser, timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3))
        await #expect(throws: (any Error).self) { try await signIn.connect(app(notion)) }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func theIPhonePasteRouteAddsThenStartsSignInForACatalogEntry() async throws {
        let rpc = oauthGateway()
        let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, url: "https://mcp.notion.com/mcp")
        let session = try await pasteSession(customService(rpc), app(notion))
        #expect(await session.submit("http://127.0.0.1:50123/callback?code=abc&state=st-1") == .signedIn)
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.oauth.start", "mcp.servers.oauth.callback", "mcp.servers.oauth.poll"])
    }

    @Test func anApiKeyEntryAsksForTheTokenBeforeTouchingTheGateway() async {
        let rpc = CustomRPC([:])
        let github = catalogEntry("github", "GitHub", "Developer", method: .apiKey, url: "https://api.githubcopilot.com/mcp/")
        await #expect(throws: ConnectAppsError.credentialsRequired(["token"])) { try await customService(rpc).connect(app(github)) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func anApiKeyEntryIsAddedWithItsBearerTokenInOneCall() async throws {
        let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }])
        let github = catalogEntry("github", "GitHub", "Developer", method: .apiKey, url: "https://api.githubcopilot.com/mcp/")
        try await customService(rpc).connect(app(github), credentials: ["token": "s3cret"])
        #expect(rpc.methods() == ["mcp.servers.add"])
        #expect(rpc.params("mcp.servers.add").first?["bearer_token"]?.stringValue == "s3cret")
    }

    @Test func updatingAnAddedApiKeyEntryReplacesTheTokenInPlace() async throws {
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) },
            "mcp.servers.update": { _ in ["ok": true] },
        ])
        let github = catalogEntry("github", "GitHub", "Developer", method: .apiKey, status: .connected, url: "https://api.githubcopilot.com/mcp/")
        try await customService(rpc).connect(app(github), credentials: ["token": "fresh"])
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.update"])
        let sent = try #require(rpc.params("mcp.servers.update").first)
        #expect(sent["auth"]?.stringValue == "bearer" && sent["bearer_token"]?.stringValue == "fresh" && sent["name"]?.stringValue == "github")
    }

    @Test func anEntryThatNeedsSetupNeverReachesTheGateway() async {
        let rpc = CustomRPC([:])
        let acme = catalogEntry("acme", "Acme", "Developer", method: .oauthClient, status: .needsSetup, url: nil)
        await #expect(throws: ConnectAppsError.oauthClient(.needsSetup)) { try await customService(rpc).connect(app(acme)) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func disconnectingACatalogEntryRemovesItsServerOnly() async throws {
        let rpc = CustomRPC(["mcp.servers.remove": { _ in ["ok": true, "removed": true] }])
        try await customService(rpc).disconnect(app(catalogEntry("slack", "Slack", "Communication", method: .mcpOAuth, status: .connected)))
        #expect(rpc.methods() == ["mcp.servers.remove"])
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "slack")
    }

    @Test func aRefusedApiKeyEntryTokenIsReportedAfterTheServerTestsIt() async {
        let rpc = CustomRPC(["mcp.servers.test": { _ in ["ok": false, "reason": "auth_refused", "tools": []] }])
        let github = catalogEntry("github", "GitHub", "Developer", method: .apiKey, status: .connected)
        #expect(await customService(rpc).tokenFailure(app(github)) == .authRefused)
    }
}
