import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class ScriptedCallbackBrowser: CallbackAuthorizationBrowser {
    enum Script: Sendable {
        case callback(String)
        case closed
    }

    private let script: Script
    let authenticated = Mutex<[(url: URL, scheme: String)]>([])
    let presented = Mutex<[URL]>([])

    init(_ script: Script) { self.script = script }

    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        authenticated.withLock { $0.append((url, callbackScheme)) }
        switch script {
        case .callback(let text): return try #require(URL(string: text))
        case .closed: throw SignInError.cancelled
        }
    }

    func present(_ url: URL) async throws {
        presented.withLock { $0.append(url) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "redirect_uri" })?.value, var back = URLComponents(string: target) else { return }
        back.queryItems = [URLQueryItem(name: "code", value: "loop-code"), URLQueryItem(name: "state", value: "st-1")]
        _ = try await URLSession.shared.data(from: back.url!)
        try await Task.sleep(for: .seconds(10))
    }

    func dismiss() async {}
}

private func gateway(redirect: String?, rejectScheme: Bool = false) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.oauth.start": { params in
            let offered = params["client_redirect_uri"]?.stringValue ?? ""
            if rejectScheme, !offered.hasPrefix("http") { throw GatewayTransportError.rpc(RPCError(code: 4001, message: "bad redirect")) }
            let used = params["fallback_redirect_uri"]?.stringValue ?? offered
            let shown = redirect == "loopback" || redirect == nil ? used : offered
            let encoded = shown.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=\(encoded)"
            var reply: JSONValue = ["session_id": "s1", "auth_url": .string(link), "redirect_uri": .string(shown)]
            if let redirect { reply = reply.merging(["redirect": .string(redirect)]) }
            return reply
        },
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { _ in ["status": "approved"] },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

private extension JSONValue {
    func merging(_ extra: [String: JSONValue]) -> JSONValue {
        var object = objectValue ?? [:]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }
}

private let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, url: "https://mcp.notion.com/mcp")
private let notionApp = ConnectApp(
    id: "connector:notion", name: "Notion", summary: "", category: "Files and docs", source: .catalog(notion), state: .disconnected
)
private let appCallback = "dev.tsnanh.hermes.bot:/mcp-oauth/callback?code=app-code&state=st-1"

private func service(_ rpc: CustomRPC, _ browser: ScriptedCallbackBrowser, scheme: PalURLScheme = .release) -> ConnectAppsService {
    ConnectAppsService(
        rpc: rpc, profile: nil, browser: browser, timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3),
        urlScheme: scheme)
}

@Suite("MCP sign-in returns to the app")
struct McpAppRedirectTests {
    @Test(arguments: [ConnectorPlatform.mac, .iPhone, .iPad])
    func theAppRedirectRelaysTheCodeFromTheCallbackAddress(_ platform: ConnectorPlatform) async throws {
        let rpc = gateway(redirect: "app")
        let browser = ScriptedCallbackBrowser(.callback(appCallback))
        guard case .connected = try await service(rpc, browser).signInMcp(notionApp, platform: platform) else {
            Issue.record("expected connected")
            return
        }
        let start = try #require(rpc.params("mcp.servers.oauth.start").first)
        #expect(start["client_redirect_uri"]?.stringValue == "dev.tsnanh.hermes.bot:/mcp-oauth/callback")
        #expect(start["fallback_redirect_uri"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(browser.authenticated.withLock { $0.first?.scheme } == "dev.tsnanh.hermes.bot")
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["code"]?.stringValue == "app-code" && relayed["state"]?.stringValue == "st-1")
        #expect(rpc.methods().last == "mcp.servers.oauth.poll")
    }

    @Test func aDevelopmentBuildOffersAndListensOnItsOwnScheme() async throws {
        let rpc = gateway(redirect: "app")
        let browser = ScriptedCallbackBrowser(.callback("dev.tsnanh.hermes.bot.dev:/mcp-oauth/callback?code=app-code&state=st-1"))
        guard case .connected = try await service(rpc, browser, scheme: .development).signInMcp(notionApp, platform: .mac) else {
            Issue.record("expected connected")
            return
        }
        let start = try #require(rpc.params("mcp.servers.oauth.start").first)
        #expect(start["client_redirect_uri"]?.stringValue == "dev.tsnanh.hermes.bot.dev:/mcp-oauth/callback")
        #expect(browser.authenticated.withLock { $0.first?.scheme } == "dev.tsnanh.hermes.bot.dev")
    }

    @Test(arguments: [ConnectorPlatform.mac, .iPhone])
    func theGatewayRedirectRelaysNothingAndPollsForApproval(_ platform: ConnectorPlatform) async throws {
        let rpc = gateway(redirect: "gateway")
        let browser = ScriptedCallbackBrowser(.callback("dev.tsnanh.hermes.bot://mcp-oauth/done"))
        guard case .connected = try await service(rpc, browser).signInMcp(notionApp, platform: platform) else {
            Issue.record("expected connected")
            return
        }
        #expect(rpc.params("mcp.servers.oauth.callback").isEmpty)
        #expect(rpc.methods().contains("mcp.servers.oauth.poll"))
    }

    @Test func theLoopbackRedirectOnTheMacRelaysThroughTheListener() async throws {
        let rpc = gateway(redirect: "loopback")
        let browser = ScriptedCallbackBrowser(.closed)
        try await service(rpc, browser).connect(ConnectApp(
            id: "connector:notion", name: "Notion", summary: "", category: "Files", source: .catalog(notion), state: .disconnected
        ))
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["code"]?.stringValue == "loop-code")
        #expect(browser.authenticated.withLock { $0.isEmpty })
    }

    @Test func theLoopbackRedirectOnTheIPhoneHandsBackThePasteSession() async throws {
        let rpc = gateway(redirect: "loopback")
        let browser = ScriptedCallbackBrowser(.closed)
        guard case .paste(let session) = try await service(rpc, browser).signInMcp(notionApp, platform: .iPhone) else {
            Issue.record("expected paste")
            return
        }
        let fallback = try #require(rpc.params("mcp.servers.oauth.start").first?["fallback_redirect_uri"]?.stringValue)
        #expect(await session.submit("\(fallback)?code=abc&state=st-1") == .signedIn)
        #expect(browser.authenticated.withLock { $0.isEmpty })
    }

    @Test func aGatewayThatDoesNotSayWhereItRedirectsIsTreatedAsLoopback() async throws {
        let rpc = gateway(redirect: nil)
        guard case .paste = try await service(rpc, ScriptedCallbackBrowser(.closed)).signInMcp(notionApp, platform: .iPhone) else {
            Issue.record("expected paste")
            return
        }
    }

    @Test func anOldGatewayThatRejectsTheSchemeIsRetriedOnceOnTheLegacyPath() async throws {
        let rpc = gateway(redirect: nil, rejectScheme: true)
        guard case .paste = try await service(rpc, ScriptedCallbackBrowser(.closed)).signInMcp(notionApp, platform: .iPhone) else {
            Issue.record("expected paste")
            return
        }
        let starts = rpc.params("mcp.servers.oauth.start")
        #expect(starts.count == 2)
        #expect(starts[1]["client_redirect_uri"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(starts[1]["fallback_redirect_uri"] == nil)
    }

    @Test(arguments: ["app", "gateway"])
    func closingTheBrowserCancelsTheFlowAndRemovesTheFreshServer(_ redirect: String) async throws {
        let rpc = gateway(redirect: redirect)
        await #expect(throws: ConnectAppsError.cancelled) {
            _ = try await service(rpc, ScriptedCallbackBrowser(.closed)).signInMcp(notionApp, platform: .iPhone)
        }
        #expect(rpc.params("mcp.servers.oauth.cancel").first?["session_id"]?.stringValue == "s1")
        #expect(rpc.params("mcp.servers.oauth.callback").isEmpty)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }
}
