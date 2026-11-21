import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

struct DeviceVendor: Sendable, CustomTestStringConvertible {
    let slug: String
    let url: String

    var testDescription: String { slug }
}

private let deviceVendors = [
    DeviceVendor(slug: "circleci", url: "https://mcp.circleci.com/v1/mcp"),
    DeviceVendor(slug: "gamma", url: "https://mcp.gamma.app/mcp"),
    DeviceVendor(slug: "intercom", url: "https://mcp.intercom.com/mcp"),
    DeviceVendor(slug: "vercel", url: "https://mcp.vercel.com"),
    DeviceVendor(slug: "upwork", url: "https://mcp.upwork.com/mcp"),
]

private func row(_ slug: String, url: String? = nil, signIn: JSONValue? = nil, accounts: [String] = []) -> JSONValue {
    var object: [String: JSONValue] = [
        "slug": .string(slug), "name": .string(slug.capitalized), "method": "mcp_oauth", "status": "not_connected",
        "multi_account": true, "accounts": .array(accounts.map { ["name": .string($0), "status": "connected"] }),
    ]
    if let url { object["mcp_url"] = .string(url) }
    if let signIn { object["sign_in"] = signIn }
    return .object(object)
}

private func entry(_ value: JSONValue) throws -> PalCatalogEntry {
    try value.decoded(as: PalCatalogEntry.self)
}

private func app(_ value: JSONValue, state: ConnectAppState = .disconnected) throws -> ConnectApp {
    let decoded = try entry(value)
    return ConnectApp(id: "connector:\(decoded.slug)", name: decoded.name, summary: "", category: "Other", source: .catalog(decoded), state: state)
}

private final class VendorTransport: HTTPTransport, Sendable {
    let paths: [String: String]

    init(url: String) {
        let all = deviceVendors.map(\.url) + [UpworkConnector.serverURL.absoluteString, url]
        let pairs = all.map { raw -> (String, String) in
            let parsed = URL(string: raw)!
            return (parsed.host()!, parsed.path.isEmpty ? "/" : parsed.path)
        }
        paths = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        let host = url.host() ?? ""
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", paths[host] ?? "?"):
            let challenge = #"Bearer resource_metadata="https://\#(host)/.well-known/oauth-protected-resource""#
            return reply(url, 401, headers: ["WWW-Authenticate": challenge], json: [:])
        case ("GET", "/.well-known/oauth-protected-resource"):
            return reply(url, 200, json: ["resource": "https://\(host)\(paths[host] ?? "/")", "authorization_servers": ["https://auth.example.com"]])
        case ("GET", "/.well-known/oauth-authorization-server"):
            return reply(url, 200, json: [
                "issuer": "https://auth.example.com", "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token", "registration_endpoint": "https://auth.example.com/register",
                "code_challenge_methods_supported": ["S256"],
            ])
        case ("POST", "/register"):
            let uris = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["redirect_uris"] as? [String] ?? []
            guard uris.allSatisfy({ $0.hasPrefix("http://127.0.0.1:") }) else { return reply(url, 400, json: ["error": "invalid_redirect_uri"]) }
            return reply(url, 201, json: ["client_id": "client-loopback"])
        case ("POST", "/token"):
            return reply(url, 200, json: ["access_token": "AT-device", "token_type": "Bearer", "expires_in": 3600])
        default:
            return reply(url, 404, json: [:])
        }
    }

    private func reply(_ url: URL, _ status: Int, headers: [String: String] = [:], json: [String: Any]) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return HTTPResult(data: data, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

private func pasteAnswer(_ session: McpPasteSession) -> String {
    let items = query(session.authorizeURL)
    return "\(items["redirect_uri"] ?? "")?code=the-code&state=\(items["state"] ?? "")"
}

private func nativeSignIn(rpc: CustomRPC, browser: any AuthorizationBrowser = IdleBrowser()) -> McpNativeSignIn {
    let transport = VendorTransport(url: UpworkConnector.serverURL.absoluteString)
    let flow = McpOAuthFlow(resource: UpworkConnector.serverURL, transport: transport, browser: browser, callbackTimeout: .seconds(20))
    return McpNativeSignIn(flow: flow, rpc: rpc)
}

private func gateway(catalog: [JSONValue] = []) -> CustomRPC {
    CustomRPC([
        "auth.submit_oauth_tokens": { _ in ["ok": true] },
        "mcp.servers.add": { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "connectors.catalog": { _ in ["connectors": .array(catalog)] },
    ])
}

private func service(_ rpc: CustomRPC, vendor url: String, browser: any AuthorizationBrowser = IdleBrowser()) -> ConnectAppsService {
    let transport = VendorTransport(url: url)
    let flow = McpOAuthFlow(resource: UpworkConnector.serverURL, transport: transport, browser: browser, callbackTimeout: .seconds(20))
    return ConnectAppsService(
        rpc: rpc, profile: nil, browser: IdleBrowser(), nativeSignIn: McpNativeSignIn(flow: flow, rpc: rpc),
        timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
    )
}

@Suite("Device sign-in field on the catalog row")
struct DeviceSignInFieldTests {
    @Test func theGatewaysFieldIsAuthoritative() throws {
        #expect(try entry(row("circleci", signIn: "device")).signIn == .device)
        #expect(try entry(row("slack", signIn: "gateway")).signIn == .gateway)
        #expect(try entry(row("upwork", signIn: "gateway")).signIn == .gateway)
        #expect(try entry(row("linear", signIn: "someday")).signIn == .gateway)
        #expect(try entry(row("linear", signIn: 3)).signIn == .gateway)
    }

    @Test func aRowFromAnOlderGatewayKeepsUpworkOnTheDeviceAndEveryoneElseOnTheGateway() throws {
        #expect(try entry(row("upwork")).signIn == .device)
        for other in ["circleci", "gamma", "intercom", "vercel", "linear", "slack"] {
            #expect(try entry(row(other)).signIn == .gateway)
        }
    }

    @Test func aBuiltEntryDefaultsToTheGateway() {
        #expect(PalCatalogEntry(slug: "upwork", name: "Upwork", method: .mcpOAuth).signIn == .gateway)
    }
}

@Suite("Which connectors sign in on the device")
struct DeviceSignInRouteTests {
    @Test func eachOfTheFiveVendorsTakesTheDeviceRoute() throws {
        for vendor in deviceVendors {
            let connector = try app(row(vendor.slug, url: vendor.url, signIn: "device"))
            #expect(connector.requiresAppSignIn, "\(vendor.slug)")
            #expect(connector.usesMcpSignIn)
        }
    }

    @Test func everyOtherConnectorKeepsTheGatewayRoute() throws {
        for slug in ["slack", "linear", "notion", "stripe"] {
            let connector = try app(row(slug, url: "https://mcp.\(slug).example/mcp", signIn: "gateway"))
            #expect(!connector.requiresAppSignIn, "\(slug)")
            #expect(connector.usesMcpSignIn)
        }
    }

    @Test func aPresetIsNeverRoutedByItsName() {
        let preset = ConnectApp(id: "mcp:upwork", name: "Upwork", summary: "", category: "", source: .mcp(name: "upwork", requires: []), state: .disconnected)
        #expect(!preset.requiresAppSignIn)
    }

    @Test func theCatalogBuildsEachRowWithItsOwnRoute() throws {
        let linear = try entry(row("linear", url: "https://mcp.linear.app/mcp", signIn: "gateway"))
        let rows = try deviceVendors.map { try entry(row($0.slug, url: $0.url, signIn: "device")) } + [linear]
        let catalog = ConnectCatalog.make(catalog: rows, mcp: [])
        #expect(Set(catalog.apps.filter(\.requiresAppSignIn).map(\.name)) == Set(deviceVendors.map { $0.slug.capitalized }))
    }
}

@Suite("Device sign-in for each vendor")
struct DeviceSignInVendorTests {
    @Test(arguments: deviceVendors.filter { $0.slug != "upwork" })
    func theSignInServiceNamesTheVendorsOwnAccount(vendor: DeviceVendor) async throws {
        let rows = [row(vendor.slug, url: vendor.url, signIn: "device", accounts: ["default", "work"])]
        let gateway = gateway(catalog: rows)
        let session = try await nativeSignIn(rpc: gateway).beginPaste(service: "mcp:\(vendor.slug):work")
        let slashes = CharacterSet(charactersIn: "/")
        #expect(query(session.authorizeURL)["resource"]?.trimmingCharacters(in: slashes) == vendor.url.trimmingCharacters(in: slashes))
        #expect(query(session.authorizeURL)["prompt"] == "select_account login")
        #expect(query(session.authorizeURL)["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(await session.submit(pasteAnswer(session)) == .signedIn)
        #expect(gateway.params("auth.submit_oauth_tokens").first?["service"]?.stringValue == "mcp:\(vendor.slug):work")
    }

    @Test func aServiceTheGatewaySignsInOrDoesNotKnowIsRefusedBeforeAnyRegistration() async throws {
        let rows = [row("linear", url: "https://mcp.linear.app/mcp", signIn: "gateway")]
        let gateway = gateway(catalog: rows)
        for service in ["mcp:linear", "mcp:nothing-here", "mcp:circleci:work"] {
            await #expect(throws: McpOAuthError.tokenExchangeFailed) {
                _ = try await nativeSignIn(rpc: gateway).beginPaste(service: service)
            }
        }
        #expect(gateway.methods().filter { $0 == "auth.submit_oauth_tokens" }.isEmpty)
    }

    @Test func aSecondAccountOnAMacRunsTheLoopbackFlowAgainstTheVendorAndHandsOverItsAlias() async throws {
        let vendor = deviceVendors[0]
        let gateway = gateway(catalog: [row(vendor.slug, url: vendor.url, signIn: "device", accounts: ["default"])])
        let browser = ReturningLoopbackBrowser()
        let connector = try app(row(vendor.slug, url: vendor.url, signIn: "device", accounts: ["default"]), state: .connected)
        let account = ConnectorAccountTarget(name: "work", create: true, selectsAccount: true)
        try await service(gateway, vendor: vendor.url, browser: browser).connectOnDevice(connector, account: account)
        #expect(gateway.params("auth.submit_oauth_tokens").first?["service"]?.stringValue == "mcp:circleci:work")
        #expect(query(try #require(browser.opened.withLock { $0.first }))["prompt"] == "select_account login")
        #expect(!gateway.methods().contains("mcp.servers.add") && !gateway.methods().contains("mcp.servers.remove"))
    }

    @Test func aFirstConnectAddsTheConnectorsPresetAndAFailedSignInRemovesIt() async throws {
        let vendor = deviceVendors[3]
        let gateway = gateway()
        let connector = try app(row(vendor.slug, url: vendor.url, signIn: "device"))
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.browserUnavailable.reason)) {
            try await service(gateway, vendor: vendor.url, browser: RefusingLoopbackBrowser()).connect(connector)
        }
        #expect(gateway.params("mcp.servers.add").first?["preset"]?.stringValue == "vercel")
        #expect(gateway.params("mcp.servers.remove").first?["name"]?.stringValue == "vercel")
    }
}

@MainActor
@Suite("A refusal from the gateway moves a stale row to the device")
struct DeviceSignInRefusalTests {
    @Test func theGatewaysDeviceRefusalOpensTheDeviceSignInForTheSameConnector() async throws {
        let vendor = deviceVendors[1]
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
            "mcp.servers.oauth.start": rpcFailure(4034, reason: "SIGNIN_ON_DEVICE", message: "This app signs in on your own device."),
            "connectors.catalog": { _ in ["connectors": []] },
        ])
        let opened = OpenedLinks()
        let transport = VendorTransport(url: vendor.url)
        let flow = McpOAuthFlow(resource: UpworkConnector.serverURL, transport: transport, browser: IdleBrowser(), callbackTimeout: .seconds(20))
        let service = ConnectAppsService(
            rpc: rpc, profile: nil, browser: IdleBrowser(), nativeSignIn: McpNativeSignIn(flow: flow, rpc: rpc),
            timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
        )
        let stale = try app(row(vendor.slug, url: vendor.url, signIn: "gateway"))
        #expect(!stale.requiresAppSignIn)
        let sheet = McpSignInController(app: stale, service: service, platform: .iPhone, openLink: { url in opened.add(url); return true }, finished: {})
        await sheet.start()
        #expect(sheet.phase == .pasteAddress)
        #expect(query(try #require(opened.urls.first))["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(rpc.methods().contains("mcp.servers.oauth.start"))
        #expect(rpc.params("mcp.servers.add").contains { $0["preset"]?.stringValue == "gamma" })
        await sheet.cancel()
    }
}

private final class ReturningLoopbackBrowser: AuthorizationBrowser {
    let opened = Mutex<[URL]>([])

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

private struct RefusingLoopbackBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws { throw McpOAuthError.browserUnavailable }
    func dismiss() async {}
}
