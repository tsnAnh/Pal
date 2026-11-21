import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

private final class AccountAuthServer: HTTPTransport, Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        switch (request.httpMethod ?? "GET", url.host() ?? "", url.path) {
        case ("GET", "mcp.upwork.com", "/mcp"):
            let challenge = #"Bearer resource_metadata="https://mcp.upwork.com/.well-known/oauth-protected-resource""#
            return reply(url, 401, headers: ["WWW-Authenticate": challenge], json: [:])
        case ("GET", "mcp.upwork.com", "/.well-known/oauth-protected-resource"):
            return reply(url, 200, json: ["resource": "https://mcp.upwork.com/mcp", "authorization_servers": ["https://auth.example.com"]])
        case ("GET", _, "/.well-known/oauth-authorization-server"):
            return reply(url, 200, json: [
                "issuer": "https://auth.example.com", "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token", "registration_endpoint": "https://auth.example.com/register",
                "code_challenge_methods_supported": ["S256"],
            ])
        case ("POST", _, "/register"):
            return reply(url, 201, json: ["client_id": "client-123"])
        case ("POST", _, "/token"):
            return reply(url, 200, json: ["access_token": "AT-account", "refresh_token": "RT-account", "token_type": "Bearer", "expires_in": 3600])
        default:
            return reply(url, 404, json: [:])
        }
    }

    private func reply(_ url: URL, _ status: Int, headers: [String: String] = [:], json: [String: Any]) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return HTTPResult(data: data, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

private final class ReturningBrowser: AuthorizationBrowser {
    private let opened = Mutex<[URL]>([])
    var openedURLs: [URL] { opened.withLock { $0 } }

    func present(_ url: URL) async throws {
        opened.withLock { $0.append(url) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
        let state = items.first { $0.name == "state" }?.value ?? ""
        _ = try await URLSession.shared.data(from: URL(string: "\(redirect)?code=the-code&state=\(state)")!)
        try await Task.sleep(for: .seconds(60))
    }

    func dismiss() async {}
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

private func flow(_ browser: any AuthorizationBrowser = IdleBrowser()) -> McpOAuthFlow {
    McpOAuthFlow(resource: UpworkConnector.serverURL, transport: AccountAuthServer(), browser: browser, callbackTimeout: .seconds(20))
}

private func rpc(catalog: CustomRPC.Reply? = nil) -> CustomRPC {
    var replies: [String: CustomRPC.Reply] = [
        "auth.submit_oauth_tokens": { _ in ["ok": true] },
        "mcp.servers.add": { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
    ]
    if let catalog { replies["connectors.catalog"] = catalog }
    return CustomRPC(replies)
}

private func catalogWith(_ accounts: [String]) -> CustomRPC.Reply {
    { _ in
        ["connectors": [[
            "slug": "upwork", "name": "Upwork", "method": "mcp_oauth", "status": "connected", "multi_account": true,
            "accounts": .array(accounts.map { ["name": .string($0), "status": "connected"] }),
        ]]]
    }
}

private func submittedService(_ rpc: CustomRPC) -> String? {
    rpc.params("auth.submit_oauth_tokens").first?["service"]?.stringValue
}

private func pasteAnswer(_ session: McpPasteSession) -> String {
    let items = query(session.authorizeURL)
    return "\(items["redirect_uri"] ?? "")?code=the-code&state=\(items["state"] ?? "")"
}

private let work = ConnectorAccountTarget(name: "work", create: true, selectsAccount: true)
private let first = ConnectorAccountTarget(name: "default", create: true, selectsAccount: false)

@Suite("Account hand-off service name")
struct AccountHandoffServiceTests {
    @Test func noAccountKeepsThePlainServiceName() async throws {
        let gateway = rpc()
        try await McpNativeSignIn(flow: flow(ReturningBrowser()), rpc: gateway).run()
        #expect(submittedService(gateway) == "mcp:upwork")
    }

    @Test func anAccountAppendsItsAlias() async throws {
        let gateway = rpc()
        try await McpNativeSignIn(flow: flow(ReturningBrowser()), rpc: gateway).run(account: first)
        #expect(submittedService(gateway) == "mcp:upwork:default")
    }

    @Test func thePasteRouteHandsOffToTheChosenAccountOnly() async throws {
        let gateway = rpc()
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(account: work)
        #expect(await session.submit(pasteAnswer(session)) == .signedIn)
        #expect(submittedService(gateway) == "mcp:upwork:work")
        #expect(gateway.params("auth.submit_oauth_tokens").count == 1)
    }

    @Test func thePasteRouteWithoutAnAccountKeepsThePlainName() async throws {
        let gateway = rpc()
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste()
        #expect(await session.submit(pasteAnswer(session)) == .signedIn)
        #expect(submittedService(gateway) == "mcp:upwork")
    }
}

@Suite("Account prompt on the app-built authorization link")
struct AccountPromptTests {
    @Test func aSecondAccountAsksTheProviderToChooseAndSignInAgain() async throws {
        let browser = ReturningBrowser()
        try await McpNativeSignIn(flow: flow(browser), rpc: rpc()).run(account: work)
        let link = try #require(browser.openedURLs.first)
        #expect(query(link)["prompt"] == "select_account login")
        #expect(McpOAuthFlow.accountPrompt == "select_account login")
    }

    @Test func theFirstAccountAddsNoPrompt() async throws {
        let browser = ReturningBrowser()
        try await McpNativeSignIn(flow: flow(browser), rpc: rpc()).run(account: first)
        #expect(query(try #require(browser.openedURLs.first))["prompt"] == nil)
    }

    @Test func noAccountAddsNoPrompt() async throws {
        let browser = ReturningBrowser()
        try await McpNativeSignIn(flow: flow(browser), rpc: rpc()).run()
        #expect(query(try #require(browser.openedURLs.first))["prompt"] == nil)
    }

    @Test func thePasteLinkCarriesThePromptForASecondAccount() async throws {
        let session = try await McpNativeSignIn(flow: flow(), rpc: rpc()).beginPaste(account: work)
        #expect(query(session.authorizeURL)["prompt"] == "select_account login")
        let plain = try await McpNativeSignIn(flow: flow(), rpc: rpc()).beginPaste(account: first)
        #expect(query(plain.authorizeURL)["prompt"] == nil)
    }

    @Test func aPromptTheProviderAlreadyAsksForIsNeverOverwritten() throws {
        let asked = URL(string: "https://auth.example.com/authorize?prompt=consent&state=s")!
        let link = McpOAuthFlow.addingPrompt(McpOAuthFlow.accountPrompt, to: asked)
        let prompts = (URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == "prompt" }
        #expect(prompts.map(\.value) == ["consent"])
        let plain = URL(string: "https://auth.example.com/authorize?state=s")!
        #expect(query(McpOAuthFlow.addingPrompt(McpOAuthFlow.accountPrompt, to: plain))["prompt"] == "select_account login")
        #expect(McpOAuthFlow.addingPrompt(nil, to: plain) == plain)
    }
}

@Suite("Re-sign-in of one named account")
struct AccountReauthSignInTests {
    @Test func theServiceNamesTheAccountToSignBackIn() async throws {
        let gateway = rpc(catalog: catalogWith(["default", "work"]))
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: "mcp:upwork:work")
        #expect(await session.submit(pasteAnswer(session)) == .signedIn)
        #expect(submittedService(gateway) == "mcp:upwork:work")
    }

    @Test func oneOfSeveralAccountsAsksTheProviderToChoose() async throws {
        let gateway = rpc(catalog: catalogWith(["default", "work"]))
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: "mcp:upwork:work")
        #expect(query(session.authorizeURL)["prompt"] == "select_account login")
    }

    @Test func theOnlyAccountDoesNotAddAPrompt() async throws {
        let gateway = rpc(catalog: catalogWith(["work"]))
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: "mcp:upwork:work")
        #expect(query(session.authorizeURL)["prompt"] == nil)
    }

    @Test func anUnreadableAccountListFailsSafeToAskingTheProvider() async throws {
        let gateway = rpc(catalog: rpcFailure(500))
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: "mcp:upwork:work")
        #expect(query(session.authorizeURL)["prompt"] == "select_account login")
    }

    @Test func thePlainServiceSignsInWithNoAccountAndNoCatalogRead() async throws {
        let gateway = rpc()
        let session = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: "mcp:upwork")
        #expect(await session.submit(pasteAnswer(session)) == .signedIn)
        #expect(submittedService(gateway) == "mcp:upwork")
        #expect(!gateway.methods().contains("connectors.catalog"))
    }

    @Test(arguments: ["mcp:linear:work", "google:workspace", "mcp:upwork:Bad Name", ""])
    func aServiceThatIsNotThisConnectorIsRefused(_ service: String) async {
        let gateway = rpc()
        await #expect(throws: McpOAuthError.tokenExchangeFailed) { _ = try await McpNativeSignIn(flow: flow(), rpc: gateway).beginPaste(service: service) }
        #expect(gateway.methods().isEmpty)
    }
}

private func upworkApp(state: ConnectAppState = .connected) -> ConnectApp {
    ConnectApp(id: "mcp:upwork", name: "Upwork", summary: "", category: "Other", source: .mcp(name: "upwork", requires: []), state: state)
}

private func serviceWith(_ gateway: CustomRPC) -> ConnectAppsService {
    ConnectAppsService(
        rpc: gateway, profile: nil, browser: IdleBrowser(),
        nativeSignIn: McpNativeSignIn(flow: flow(), rpc: gateway),
        timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
    )
}

@Suite("Upwork account connect and rollback")
struct UpworkAccountConnectTests {
    @Test func aSecondAccountPasteHandsOffToItsAliasAndNeverRemovesTheServer() async throws {
        let gateway = rpc()
        let session = try await serviceWith(gateway).beginUpworkPaste(upworkApp(), account: work)
        #expect(query(session.authorizeURL)["prompt"] == "select_account login")
        await session.cancel()
        #expect(!gateway.methods().contains("mcp.servers.remove"))
        #expect(!gateway.methods().contains("mcp.servers.add"))
    }

    @Test func aFirstAttemptThatIsCancelledRemovesTheServerItAddedWithNoAccount() async throws {
        let gateway = rpc()
        let session = try await serviceWith(gateway).beginUpworkPaste(upworkApp(state: .disconnected), account: first)
        await session.cancel()
        let removal = try #require(gateway.params("mcp.servers.remove").first)
        #expect(removal["name"]?.stringValue == "upwork")
        #expect(removal["account"] == nil)
    }

    @Test func aSecondAccountMacSignInHandsOffToItsAlias() async throws {
        let gateway = rpc()
        let browser = ReturningBrowser()
        let service = ConnectAppsService(
            rpc: gateway, profile: nil, browser: IdleBrowser(),
            nativeSignIn: McpNativeSignIn(flow: flow(browser), rpc: gateway),
            timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
        )
        try await service.connectUpwork(upworkApp(), account: work)
        #expect(submittedService(gateway) == "mcp:upwork:work")
        #expect(query(try #require(browser.openedURLs.first))["prompt"] == "select_account login")
        #expect(!gateway.methods().contains("mcp.servers.remove"))
    }
}

@MainActor
@Suite("Sign-in sheet model for accounts")
struct AccountSignInControllerTests {
    private func controller(
        _ gateway: CustomRPC, app: ConnectApp, account: ConnectorAccountTarget?, platform: ConnectorPlatform = .iPhone,
        opened: OpenedLinks
    ) -> McpSignInController {
        McpSignInController(
            app: app, service: serviceWith(gateway), platform: platform, account: account,
            openLink: { url in opened.add(url); return true }, finished: {}
        )
    }

    @Test func theHintIsOneProductLanguageSentence() {
        let hint = McpSignInSteps.privateWindowHint
        #expect(hint == "If the sign-in page skips the account choice, use a private window.")
        #expect(!hint.contains("\n"))
    }

    @Test func aSecondUpworkAccountSurfacesTheHintAndOpensTheLinkOnce() async throws {
        let gateway = rpc()
        let opened = OpenedLinks()
        let model = controller(gateway, app: upworkApp(), account: work, opened: opened)
        #expect(model.privateWindowHint == nil)
        await model.start()
        #expect(model.phase == .pasteAddress)
        #expect(model.privateWindowHint == McpSignInSteps.privateWindowHint)
        #expect(opened.urls.count == 1)
        #expect(query(try #require(opened.urls.first))["prompt"] == "select_account login")
        await model.cancel()
    }

    @Test func theFirstUpworkAccountShowsNoHint() async {
        let opened = OpenedLinks()
        let model = controller(rpc(), app: upworkApp(state: .disconnected), account: first, opened: opened)
        await model.start()
        #expect(model.phase == .pasteAddress)
        #expect(model.privateWindowHint == nil)
        await model.cancel()
    }

    private func presetApp() -> ConnectApp {
        ConnectApp(id: "mcp:notion", name: "Notion", summary: "", category: "Other", source: .mcp(name: "notion", requires: []), state: .connected)
    }

    private func startReply(hint: JSONValue?) -> CustomRPC.Reply {
        { _ in
            var reply: [String: JSONValue] = ["session_id": "s1", "auth_url": .string(authLink)]
            if let hint { reply["private_window_hint"] = hint }
            return .object(reply)
        }
    }

    private func presetGateway(hint: JSONValue?) -> CustomRPC {
        CustomRPC([
            "mcp.servers.add": { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) },
            "mcp.servers.oauth.start": startReply(hint: hint),
            "mcp.servers.oauth.cancel": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
        ])
    }

    @Test func theGatewaysPrivateWindowHintIsSurfaced() async {
        let model = controller(presetGateway(hint: true), app: presetApp(), account: work, opened: OpenedLinks())
        await model.start()
        #expect(model.phase == .pasteAddress)
        #expect(model.privateWindowHint == McpSignInSteps.privateWindowHint)
        await model.cancel()
    }

    @Test func aFalseOrMissingHintShowsNothing() async {
        for hint in [JSONValue.bool(false), nil] {
            let model = controller(presetGateway(hint: hint), app: presetApp(), account: work, opened: OpenedLinks())
            await model.start()
            #expect(model.privateWindowHint == nil)
            await model.cancel()
        }
    }

    @Test func theSystemBrowserLinkIsStillOpenedThroughTheInjectedOpener() async throws {
        let opened = OpenedLinks()
        let model = controller(presetGateway(hint: true), app: presetApp(), account: work, opened: opened)
        await model.start()
        #expect(opened.urls.map(\.absoluteString) == [authLink])
        await model.cancel()
    }
}

private let authLink = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Fcallback"

final class OpenedLinks: @unchecked Sendable {
    private let log = Mutex<[URL]>([])
    var urls: [URL] { log.withLock { $0 } }
    func add(_ url: URL) { log.withLock { $0.append(url) } }
}
