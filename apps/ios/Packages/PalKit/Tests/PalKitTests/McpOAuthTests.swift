import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import Synchronization
import Testing

private let secretAccess = "AT-secret-access-token"
private let secretRefresh = "RT-secret-refresh-token"

private final class FakeAuthServer: HTTPTransport, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var body: Data?
    }

    var challengeHeader: String? = #"Bearer resource_metadata="https://mcp.upwork.com/.well-known/oauth-protected-resource""#
    var issuer = "https://auth.example.com"
    var scopes: [String]? = ["jobs.read", "proposals.write"]
    var challengeMethods: [String]? = ["S256"]
    var registrationEndpoint = "https://auth.example.com/register"
    var tokenStatus = 200

    private let log = Mutex<[Seen]>([])

    var seen: [Seen] { log.withLock { $0 } }

    func requests(to path: String) -> [Seen] { seen.filter { $0.url.path == path } }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        log.withLock { $0.append(Seen(method: request.httpMethod ?? "GET", url: url, body: request.httpBody)) }
        switch (request.httpMethod ?? "GET", url.host() ?? "", url.path) {
        case ("GET", "mcp.upwork.com", "/mcp"):
            return reply(url, 401, headers: challengeHeader.map { ["WWW-Authenticate": $0] } ?? [:], json: [:])
        case ("GET", "mcp.upwork.com", "/.well-known/oauth-protected-resource"):
            var body: [String: Any] = ["resource": "https://mcp.upwork.com/mcp", "authorization_servers": [issuer]]
            if let scopes { body["scopes_supported"] = scopes }
            return reply(url, 200, json: body)
        case ("GET", _, "/.well-known/oauth-authorization-server"):
            var body: [String: Any] = [
                "issuer": issuer, "authorization_endpoint": "https://auth.example.com/authorize",
                "token_endpoint": "https://auth.example.com/token", "registration_endpoint": registrationEndpoint,
            ]
            if let challengeMethods { body["code_challenge_methods_supported"] = challengeMethods }
            return reply(url, 200, json: body)
        case ("POST", _, "/register"):
            return reply(url, 201, json: ["client_id": "client-123"])
        case ("POST", _, "/token"):
            let body: [String: Any] = tokenStatus == 200
                ? ["access_token": secretAccess, "refresh_token": secretRefresh, "token_type": "Bearer", "expires_in": 3600, "scope": "jobs.read proposals.write"]
                : ["error": "invalid_grant", "error_description": "code \(secretAccess) rejected"]
            return reply(url, tokenStatus, json: body)
        default:
            return reply(url, 404, json: [:])
        }
    }

    private func reply(_ url: URL, _ status: Int, headers: [String: String] = [:], json: [String: Any]) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return HTTPResult(data: data, response: response)
    }
}

private final class CallbackBrowser: AuthorizationBrowser {
    enum Mode {
        case valid
        case wrongStateThenValid
        case error
        case neverCalls
    }

    let mode: Mode
    private let opened = Mutex<[URL]>([])

    init(_ mode: Mode = .valid) { self.mode = mode }

    var openedURLs: [URL] { opened.withLock { $0 } }

    func present(_ url: URL) async throws {
        opened.withLock { $0.append(url) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
        let state = items.first { $0.name == "state" }?.value ?? ""
        switch mode {
        case .valid:
            _ = try await URLSession.shared.data(from: URL(string: "\(redirect)?code=the-code&state=\(state)")!)
        case .wrongStateThenValid:
            let (_, bad) = try await URLSession.shared.data(from: URL(string: "\(redirect)?code=evil&state=nope")!)
            #expect((bad as? HTTPURLResponse)?.statusCode == 400)
            _ = try await URLSession.shared.data(from: URL(string: "\(redirect)?code=the-code&state=\(state)")!)
        case .error:
            _ = try await URLSession.shared.data(from: URL(string: "\(redirect)?error=access_denied&state=\(state)")!)
        case .neverCalls:
            break
        }
        try await Task.sleep(for: .seconds(60))
    }

    func dismiss() async {}
}

private final class GatewayRPC: ConnectRPC {
    private let log = Mutex<[(String, JSONValue)]>([])
    let reply: JSONValue

    init(reply: JSONValue = ["ok": true]) { self.reply = reply }

    var calls: [(String, JSONValue)] { log.withLock { $0 } }
    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append((method, params)) }
        return reply
    }
}

private func flow(_ server: FakeAuthServer, _ browser: CallbackBrowser, timeout: Duration = .seconds(20)) -> McpOAuthFlow {
    McpOAuthFlow(resource: UpworkConnector.serverURL, transport: server, browser: browser, callbackTimeout: timeout)
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

private func formFields(_ data: Data?) -> [String: String] {
    guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { fields[parts[0]] = parts[1].removingPercentEncoding }
    }
    return fields
}

@Suite("MCP OAuth handshake")
struct McpOAuthHandshakeTests {
    @Test func fullHandshakeAgainstFakeServer() async throws {
        let server = FakeAuthServer()
        let browser = CallbackBrowser()
        let grant = try await flow(server, browser).authorize()

        let authorize = try #require(browser.openedURLs.first)
        let params = query(authorize)
        #expect(authorize.host() == "auth.example.com")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "client-123")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["scope"] == "jobs.read proposals.write")
        #expect(params["resource"] == "https://mcp.upwork.com/mcp")
        let redirect = try #require(params["redirect_uri"])
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/callback"))
        #expect((params["state"] ?? "").count >= 16)

        let registration = try #require(server.requests(to: "/register").first)
        let registrationBody = try #require(registration.body)
        let registered = try #require(try JSONSerialization.jsonObject(with: registrationBody) as? [String: Any])
        #expect(registered["token_endpoint_auth_method"] as? String == "none")
        #expect(registered["application_type"] as? String == "native")
        #expect(registered["redirect_uris"] as? [String] == [redirect])
        #expect(registered["grant_types"] as? [String] == ["authorization_code", "refresh_token"])

        let token = try #require(server.requests(to: "/token").first)
        let form = formFields(token.body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "the-code")
        #expect(form["client_id"] == "client-123")
        #expect(form["redirect_uri"] == redirect)
        #expect(form["client_secret"] == nil)
        let verifier = try #require(form["code_verifier"])
        #expect((43...128).contains(verifier.count))
        #expect(PKCE.challenge(for: verifier) == params["code_challenge"])

        #expect(grant.clientID == "client-123")
        #expect(grant.accessToken.reveal() == secretAccess)
        #expect(grant.refreshToken?.reveal() == secretRefresh)
        #expect(grant.expiresIn == 3600)
        #expect(grant.issuer == "https://auth.example.com")
        #expect(grant.tokenEndpoint.absoluteString == "https://auth.example.com/token")
    }

    @Test func submitsTheTokensToTheGatewayWithTheDocumentedShape() async throws {
        let server = FakeAuthServer()
        let rpc = GatewayRPC()
        let native = McpNativeSignIn(flow: flow(server, CallbackBrowser()), rpc: rpc)
        try await native.run()

        let (method, params) = try #require(rpc.calls.first)
        #expect(method == "auth.submit_oauth_tokens")
        #expect(params["service"]?.stringValue == "mcp:upwork")
        #expect(params["client_id"]?.stringValue == "client-123")
        #expect(params["redirect_uri"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(params["token_endpoint"]?.stringValue == "https://auth.example.com/token")
        #expect(params["issuer"]?.stringValue == "https://auth.example.com")
        #expect(params["access_token"]?.stringValue == secretAccess)
        #expect(params["refresh_token"]?.stringValue == secretRefresh)
        #expect(params["expires_in"]?.intValue == 3600)
        #expect(params["scope"]?.stringValue == "jobs.read proposals.write")
        #expect(params["token_type"]?.stringValue == "Bearer")
        #expect(params["profile"] == nil)
    }

    @Test func gatewayRefusalSurfacesItsReasonWithoutTokens() async throws {
        let rpc = GatewayRPC(reply: ["ok": false, "reason": "Upwork says this app isn't approved."])
        let native = McpNativeSignIn(flow: flow(FakeAuthServer(), CallbackBrowser()), rpc: rpc)
        do {
            try await native.run()
            Issue.record("expected a refusal")
        } catch {
            #expect(error as? McpOAuthError == .rejectedByGateway("Upwork says this app isn't approved."))
            expectNoSecrets(in: error)
        }
    }

    @Test func gatewayReasonCodesBecomePlainText() {
        #expect(McpOAuthSubmission.readable("save_failed") == "Your Pal couldn't save the sign-in. Try again.")
        #expect(McpOAuthSubmission.readable("Upwork says no.") == "Upwork says no.")
        #expect(McpOAuthSubmission.readable("  ") == nil)
        #expect(McpOAuthSubmission.readable(nil) == nil)
    }

    @Test func wrongStateIsRejectedAndTheRealRedirectStillWorks() async throws {
        let grant = try await flow(FakeAuthServer(), CallbackBrowser(.wrongStateThenValid)).authorize()
        #expect(grant.accessToken.reveal() == secretAccess)
    }

    @Test func providerErrorMeansDenied() async throws {
        do {
            _ = try await flow(FakeAuthServer(), CallbackBrowser(.error)).authorize()
            Issue.record("expected a denial")
        } catch {
            #expect(error as? McpOAuthError == .denied)
        }
    }

    @Test func noRedirectTimesOut() async throws {
        do {
            _ = try await flow(FakeAuthServer(), CallbackBrowser(.neverCalls), timeout: .milliseconds(300)).authorize()
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? McpOAuthError == .timedOut)
        }
    }

    @Test func failedTokenExchangeNeverEchoesTheServerText() async throws {
        let server = FakeAuthServer()
        server.tokenStatus = 400
        do {
            _ = try await flow(server, CallbackBrowser()).authorize()
            Issue.record("expected a failed exchange")
        } catch {
            #expect(error as? McpOAuthError == .tokenExchangeFailed)
            expectNoSecrets(in: error)
        }
    }

    @Test func grantDescriptionHidesTheTokens() async throws {
        let grant = try await flow(FakeAuthServer(), CallbackBrowser()).authorize()
        for text in [String(describing: grant), String(reflecting: grant), "\(grant)"] {
            #expect(!text.contains(secretAccess))
            #expect(!text.contains(secretRefresh))
        }
    }

    @Test func omitsScopeWhenTheServerListsNone() async throws {
        let server = FakeAuthServer()
        server.scopes = nil
        let browser = CallbackBrowser()
        _ = try await flow(server, browser).authorize()
        #expect(query(try #require(browser.openedURLs.first))["scope"] == nil)
        let registration = try #require(server.requests(to: "/register").first)
        let registrationBody = try #require(registration.body)
        let registered = try #require(try JSONSerialization.jsonObject(with: registrationBody) as? [String: Any])
        #expect(registered["scope"] == nil)
    }

    @Test func fallsBackToWellKnownWhenThereIsNoChallengeHint() async throws {
        let server = FakeAuthServer()
        server.challengeHeader = nil
        let grant = try await flow(server, CallbackBrowser()).authorize()
        #expect(grant.clientID == "client-123")
        #expect(server.requests(to: "/.well-known/oauth-protected-resource").count == 1)
    }

    @Test func refusesAMetadataIssuerThatDoesNotMatch() async throws {
        let server = FakeAuthServer()
        let hijacked = FakeAuthServerIssuerMismatch(inner: server)
        do {
            _ = try await McpOAuthFlow(resource: UpworkConnector.serverURL, transport: hijacked, browser: CallbackBrowser(.neverCalls)).authorize()
            Issue.record("expected discovery to fail")
        } catch {
            #expect(error as? McpOAuthError == .discoveryFailed)
        }
    }

    @Test func refusesAServerWithoutS256() async throws {
        let server = FakeAuthServer()
        server.challengeMethods = ["plain"]
        await expectDiscoveryFailure(server)
    }

    @Test func refusesInsecureEndpoints() async throws {
        let server = FakeAuthServer()
        server.registrationEndpoint = "http://auth.example.com/register"
        await expectDiscoveryFailure(server)
    }

    @Test func refusesAnInsecureResource() async throws {
        let flow = McpOAuthFlow(resource: URL(string: "http://mcp.upwork.com/mcp")!, transport: FakeAuthServer(), browser: CallbackBrowser(.neverCalls))
        await #expect(throws: McpOAuthError.discoveryFailed) { _ = try await flow.authorize() }
    }

    private func expectDiscoveryFailure(_ server: FakeAuthServer) async {
        await #expect(throws: McpOAuthError.discoveryFailed) {
            _ = try await flow(server, CallbackBrowser(.neverCalls)).authorize()
        }
    }

    private func expectNoSecrets(in error: any Error) {
        for text in [String(describing: error), String(reflecting: error), "\(error)", (error as? McpOAuthError)?.reason ?? ""] {
            #expect(!text.contains(secretAccess))
            #expect(!text.contains(secretRefresh))
        }
    }
}

private final class FakeAuthServerIssuerMismatch: HTTPTransport {
    let inner: FakeAuthServer

    init(inner: FakeAuthServer) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let result = try await inner.send(request)
        guard request.url?.path == "/.well-known/oauth-authorization-server",
              var object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        else { return result }
        object["issuer"] = "https://evil.example.com"
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: object), response: result.response)
    }
}

private func disconnectedUpwork() -> ConnectApp {
    ConnectApp(
        id: "mcp:upwork", name: "Upwork", summary: "", category: "Other", iconURL: nil,
        source: .mcp(name: "upwork", requires: []), state: .disconnected
    )
}

@Suite("Upwork connect through the service")
struct UpworkServiceConnectTests {
    @Test func withoutTheNativeFlowItIsUnavailableAndTouchesNothing() async {
        let rpc = GatewayRPC()
        let service = ConnectAppsService(rpc: rpc, profile: nil)
        await #expect(throws: ConnectAppsError.unavailable) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods.isEmpty)
    }

    @Test func addsThePresetThenSubmitsTheTokens() async throws {
        let rpc = GatewayRPC()
        let native = McpNativeSignIn(flow: flow(FakeAuthServer(), CallbackBrowser()), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        try await service.connect(disconnectedUpwork())
        #expect(rpc.methods == ["mcp.servers.add", "auth.submit_oauth_tokens"])
    }

    @Test func aRefusedSignInRemovesThePresetItJustAdded() async {
        let rpc = GatewayRPC(reply: ["ok": false, "reason": "Not approved."])
        let native = McpNativeSignIn(flow: flow(FakeAuthServer(), CallbackBrowser()), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        await #expect(throws: ConnectAppsError.signInFailed("Not approved.")) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods == ["mcp.servers.add", "auth.submit_oauth_tokens", "mcp.servers.remove"])
    }

    @Test func aTimedOutSignInRollsBackAndSaysWhy() async {
        let rpc = GatewayRPC()
        let native = McpNativeSignIn(flow: flow(FakeAuthServer(), CallbackBrowser(.neverCalls), timeout: .milliseconds(200)), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.timedOut.reason)) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods == ["mcp.servers.add", "mcp.servers.remove"])
    }
}

@Suite("MCP OAuth scopes and callback checks")
struct McpOAuthChecksTests {
    @Test func requestsEveryScopeTheServerOffersOrNone() {
        #expect(McpOAuthScopes.requested(resourceScopes: nil, serverScopes: nil) == nil)
        #expect(McpOAuthScopes.requested(resourceScopes: [], serverScopes: []) == nil)
        #expect(McpOAuthScopes.requested(resourceScopes: nil, serverScopes: ["a", "b", "a"]) == "a b")
        #expect(McpOAuthScopes.requested(resourceScopes: ["r"], serverScopes: ["a", "b"]) == "r")
    }

    @Test func acceptsOnlyAMatchingStateWithACode() throws {
        #expect(try AuthorizationCallback.code(from: ["code": "c", "state": "s"], expectedState: "s") == "c")
        #expect(throws: SignInError.stateMismatch) { try AuthorizationCallback.code(from: ["code": "c", "state": "x"], expectedState: "s") }
        #expect(throws: SignInError.stateMismatch) { try AuthorizationCallback.code(from: ["code": "c"], expectedState: "s") }
        #expect(throws: SignInError.authorizationDenied("access_denied")) {
            try AuthorizationCallback.code(from: ["error": "access_denied", "state": "s"], expectedState: "s")
        }
        #expect(throws: SignInError.missingAuthorizationCode) { try AuthorizationCallback.code(from: ["state": "s"], expectedState: "s") }
    }

    @Test func comparesStatesInFull() {
        #expect(ConstantTime.equal("abc", "abc"))
        #expect(!ConstantTime.equal("abc", "abd"))
        #expect(!ConstantTime.equal("abc", "abcd"))
        #expect(!ConstantTime.equal("", "a"))
        #expect(ConstantTime.equal("", ""))
    }

    @Test func readsTheResourceMetadataHint() {
        let header = #"Bearer realm="mcp", resource_metadata="https://mcp.upwork.com/.well-known/oauth-protected-resource""#
        #expect(McpOAuthDiscovery.resourceMetadataURL(inChallenge: header)?.absoluteString == "https://mcp.upwork.com/.well-known/oauth-protected-resource")
        #expect(McpOAuthDiscovery.resourceMetadataURL(inChallenge: "Bearer realm=\"mcp\"") == nil)
    }
}

@Suite("Loopback listener state and reuse")
struct LoopbackStateTests {
    @Test func ignoresAWrongStateThenAcceptsTheRightOne() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10), expectedState: "good")
        async let parameters = listener.awaitCallback()
        let (_, bad) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=bad")!)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a")!)
        #expect((bad as? HTTPURLResponse)?.statusCode == 400)
        #expect((missing as? HTTPURLResponse)?.statusCode == 400)
        let (_, good) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=good")!)
        #expect((good as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await parameters == ["code": "a", "state": "good"])
    }

    @Test func aSecondCallbackIsRefused() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10), expectedState: "s")
        async let parameters = listener.awaitCallback()
        _ = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=s")!)
        _ = try await parameters
        let second = try? await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=b&state=s")!)
        if let second { #expect((second.1 as? HTTPURLResponse)?.statusCode == 410) }
    }
}
