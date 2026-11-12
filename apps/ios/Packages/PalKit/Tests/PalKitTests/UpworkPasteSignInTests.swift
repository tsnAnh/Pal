import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import Synchronization
import Testing

private let canary = "CANARY-code-9f3a71d2"
private let accessToken = "AT-paste-access-token"
private let refreshToken = "RT-paste-refresh-token"
private let registered = URL(string: "http://127.0.0.1:50123/callback")!
private let expectedState = "state-abc_123"

private func code(_ result: Result<String, PasteError>) -> String? {
    if case .success(let value) = result { return value }
    return nil
}

private func failure(_ result: Result<String, PasteError>) -> PasteError? {
    if case .failure(let error) = result { return error }
    return nil
}

private func parse(_ text: String) -> Result<String, PasteError> {
    return PastedAuthorization.parse(text, expectedState: expectedState, expectedRedirect: registered)
}

@Suite("Pasted authorization parser")
struct PastedAuthorizationTests {
    @Test func readsTheFullAddress() {
        #expect(code(parse("http://127.0.0.1:50123/callback?code=abc&state=\(expectedState)")) == "abc")
        #expect(code(parse("http://localhost:50123/callback?state=\(expectedState)&code=abc")) == "abc")
        #expect(code(parse("http://127.0.0.1:50123/callback?code=a%2Bb%3D&state=\(expectedState)&iss=https%3A%2F%2Fmcp.upwork.com")) == "a+b=")
    }

    @Test func trimsWhitespaceQuotesAndBrackets() {
        let address = "http://127.0.0.1:50123/callback?code=abc&state=\(expectedState)"
        #expect(code(parse("  \n\(address)\n ")) == "abc")
        #expect(code(parse("\"\(address)\"")) == "abc")
        #expect(code(parse("<\(address)>")) == "abc")
        #expect(code(parse("\u{201C}\(address)\u{201D}")) == "abc")
    }

    @Test func readsABareQueryWithOrWithoutTheQuestionMark() {
        #expect(code(parse("code=abc&state=\(expectedState)")) == "abc")
        #expect(code(parse("?code=abc&state=\(expectedState)")) == "abc")
    }

    @Test func readsLabelledPairsOnSeparateLines() {
        #expect(code(parse("code=abc state=\(expectedState)")) == "abc")
        #expect(code(parse("code=abc\nstate=\(expectedState)")) == "abc")
        #expect(code(parse("code=abc, state=\(expectedState)")) == "abc")
        #expect(code(parse("state=\(expectedState),code=abc")) == "abc")
    }

    @Test func refusesValuesWithoutLabels() {
        #expect(failure(parse("abc \(expectedState)")) == .malformed)
        #expect(failure(parse("abc")) == .malformed)
        #expect(failure(parse("code=abc \(expectedState)")) == .malformed)
        #expect(failure(parse("=abc state=\(expectedState)")) == .malformed)
    }

    @Test func aDeniedAnswerIsDeniedAndAnyOtherErrorIsAStaticFailure() {
        #expect(failure(parse("http://127.0.0.1:50123/callback?error=access_denied&state=\(expectedState)")) == .denied)
        #expect(failure(parse("error=server_error&error_description=\(canary)&state=\(expectedState)")) == .failed)
        #expect(failure(parse("error=access_denied")) == .missingState)
    }

    @Test func requiresAMatchingState() {
        #expect(failure(parse("code=abc")) == .missingState)
        #expect(failure(parse("code=abc&state=")) == .missingState)
        #expect(failure(parse("code=abc&state=other")) == .stateMismatch)
        #expect(failure(parse("code=abc&state=\(expectedState)x")) == .stateMismatch)
        #expect(failure(parse("code=abc&state=\(expectedState.dropLast())")) == .stateMismatch)
    }

    @Test func requiresACode() {
        #expect(failure(parse("state=\(expectedState)")) == .missingCode)
        #expect(failure(parse("state=\(expectedState)&code=")) == .missingCode)
    }

    @Test func refusesRepeatedParameters() {
        #expect(failure(parse("http://127.0.0.1:50123/callback?code=a&code=b&state=\(expectedState)")) == .duplicateParameter)
        #expect(failure(parse("code=a&state=\(expectedState)&state=\(expectedState)")) == .duplicateParameter)
        #expect(failure(parse("error=access_denied&error=access_denied&state=\(expectedState)")) == .duplicateParameter)
    }

    @Test func refusesAddressesThatAreNotTheRegisteredRedirect() {
        let query = "?code=abc&state=\(expectedState)"
        #expect(failure(parse("http://127.0.0.1:50124/callback" + query)) == .wrongAddress)
        #expect(failure(parse("http://127.0.0.1/callback" + query)) == .wrongAddress)
        #expect(failure(parse("http://127.0.0.1:50123/other" + query)) == .wrongAddress)
        #expect(failure(parse("http://127.0.0.1:50123/callback/x" + query)) == .wrongAddress)
        #expect(failure(parse("http://example.com:50123/callback" + query)) == .wrongAddress)
        #expect(failure(parse("http://127.0.0.1.evil.com:50123/callback" + query)) == .wrongAddress)
        #expect(failure(parse("http://user@127.0.0.1:50123/callback" + query)) == .wrongAddress)
        #expect(failure(parse("https://127.0.0.1:50123/callback" + query)) == .wrongAddress)
        #expect(failure(parse("dev.tsnanh.hermes.bot://x" + query)) == .wrongAddress)
    }

    @Test func capsTheLengthAndRefusesEmptyInput() {
        #expect(failure(parse("code=" + String(repeating: "a", count: PastedAuthorization.maxLength))) == .tooLong)
        #expect(failure(parse("")) == .empty)
        #expect(failure(parse(" \n \"\" ")) == .empty)
    }

    @Test func errorTextIsStaticAndNeverEchoesTheInput() {
        let inputs = [
            "code=\(canary)&state=wrong",
            "code=\(canary)",
            "code=\(canary)&code=\(canary)&state=\(expectedState)",
            "http://evil.example.com/callback?code=\(canary)&state=\(expectedState)",
            "http://127.0.0.1:50123/callback?error=\(canary)&state=\(expectedState)",
            "\(canary) \(expectedState)",
            "state=\(expectedState)&error=access_denied&code=\(canary)",
        ]
        for input in inputs {
            guard let error = failure(parse(input)) else {
                Issue.record("expected a failure")
                continue
            }
            for text in [String(describing: error), String(reflecting: error), "\(error)", error.userText, error.debugDescription] {
                #expect(!text.contains(canary))
                #expect(!text.contains(expectedState))
            }
        }
    }

    @Test func onlyFormatSlipsKeepTheAttemptOpen() {
        let open: [PasteError] = [.empty, .tooLong, .malformed, .wrongAddress, .duplicateParameter, .missingState, .missingCode]
        let burned: [PasteError] = [.stateMismatch, .denied, .failed]
        #expect(open.allSatisfy(\.keepsAttemptOpen))
        #expect(burned.allSatisfy { !$0.keepsAttemptOpen })
    }
}

private final class UpworkLikeServer: HTTPTransport, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var body: Data?
    }

    var tokenStatus = 200
    private let log = Mutex<[Seen]>([])

    var seen: [Seen] { log.withLock { $0 } }

    func requests(to path: String) -> [Seen] { seen.filter { $0.url.path == path } }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        log.withLock { $0.append(Seen(method: request.httpMethod ?? "GET", url: url, body: request.httpBody)) }
        switch (request.httpMethod ?? "GET", url.host() ?? "", url.path) {
        case ("GET", "mcp.upwork.com", "/mcp"):
            return reply(url, 401, json: [:])
        case ("GET", "mcp.upwork.com", "/.well-known/oauth-protected-resource"):
            return reply(url, 200, json: [
                "resource": "https://mcp.upwork.com/mcp", "authorization_servers": ["https://mcp.upwork.com"],
                "bearer_methods_supported": ["header"], "resource_name": "Upwork MCP",
            ])
        case ("GET", "mcp.upwork.com", "/.well-known/oauth-authorization-server"):
            return reply(url, 200, json: [
                "issuer": "https://mcp.upwork.com",
                "authorization_endpoint": "https://www.upwork.com/ab/account-security/oauth2/authorize",
                "token_endpoint": "https://www.upwork.com/api/v3/oauth2/token",
                "revocation_endpoint": "https://www.upwork.com/api/v3/oauth2/token/revoke",
                "registration_endpoint": "https://www.upwork.com/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token", "client_credentials"],
                "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post", "private_key_jwt"],
                "code_challenge_methods_supported": ["S256"],
                "client_id_metadata_document_supported": true,
            ])
        case ("POST", "www.upwork.com", "/register"):
            return reply(url, 201, json: ["client_id": "client-123"])
        case ("POST", "www.upwork.com", "/api/v3/oauth2/token"):
            let form = Self.fields(request.httpBody)
            let body: [String: Any] = tokenStatus == 200
                ? ["access_token": accessToken, "refresh_token": refreshToken, "token_type": "Bearer", "expires_in": 3600]
                : ["error": "invalid_grant", "error_description": "code \(form["code"] ?? "") rejected"]
            return reply(url, tokenStatus, json: body)
        default:
            return reply(url, 404, json: [:])
        }
    }

    static func fields(_ data: Data?) -> [String: String] {
        guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].removingPercentEncoding }
        }
        return fields
    }

    private func reply(_ url: URL, _ status: Int, json: [String: Any]) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return HTTPResult(data: data, response: response)
    }
}

private final class PasteGatewayRPC: ConnectRPC {
    private let log = Mutex<[(String, JSONValue)]>([])
    var calls: [(String, JSONValue)] { log.withLock { $0 } }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append((method, params)) }
        return ["ok": true]
    }
}

private final class RollbackCounter: @unchecked Sendable {
    private let count = Mutex<Int>(0)
    var value: Int { count.withLock { $0 } }
    func bump() { count.withLock { $0 += 1 } }
}

private func query(_ url: URL) -> [String: String] {
    return Dictionary(
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

private func pastedFlow(_ server: UpworkLikeServer) -> McpOAuthFlow {
    return McpOAuthFlow(resource: UpworkConnector.serverURL, transport: server)
}

private func answer(_ handshake: McpOAuthHandshake, code: String = canary, state overrideState: String? = nil) -> String {
    let state = overrideState ?? query(handshake.authorizeURL)["state"] ?? ""
    return "\(handshake.redirectURI)?code=\(code)&state=\(state)"
}

private func allDescriptions(of value: Any) -> [String] {
    return [String(describing: value), String(reflecting: value), "\(value)", String(describing: Mirror(reflecting: value).children.map { "\($0.value)" })]
}

@Suite("Paste route handshake")
struct PasteHandshakeTests {
    @Test func theRFCVectorStillHolds() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func beginsAgainstTheRealUpworkMetadata() async throws {
        let server = UpworkLikeServer()
        let handshake = try await pastedFlow(server).beginPasted()
        let authorize = handshake.authorizeURL
        let params = query(authorize)
        #expect(authorize.host() == "www.upwork.com")
        #expect(authorize.path == "/ab/account-security/oauth2/authorize")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "client-123")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["resource"] == "https://mcp.upwork.com/mcp")
        #expect(params["scope"] == nil)
        let redirect = try #require(params["redirect_uri"])
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/callback"))
        #expect(redirect == handshake.redirectURI)
        let port = try #require(URL(string: redirect)?.port)
        #expect((49152...65535).contains(port))
        #expect((params["state"] ?? "").count >= 16)
        #expect((params["code_challenge"] ?? "").count >= 43)

        let registration = try #require(server.requests(to: "/register").first)
        #expect(registration.url.host() == "www.upwork.com")
        let registrationBody = try #require(registration.body)
        let registeredClient = try #require(try JSONSerialization.jsonObject(with: registrationBody) as? [String: Any])
        #expect(registeredClient["redirect_uris"] as? [String] == [redirect])
        #expect(registeredClient["token_endpoint_auth_method"] as? String == "none")
        #expect(registeredClient["application_type"] as? String == "native")
        #expect(registeredClient["scope"] == nil)
        #expect(server.requests(to: "/api/v3/oauth2/token").isEmpty)
    }

    @Test func exchangesThePastedCodeAtTheTokenHostWithTheVerifierAndNoSecret() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        let challenge = try #require(query(handshake.authorizeURL)["code_challenge"])
        let grant = try await flow.complete(handshake, pasted: answer(handshake))

        let token = try #require(server.requests(to: "/api/v3/oauth2/token").first)
        #expect(token.url.host() == "www.upwork.com")
        let form = UpworkLikeServer.fields(token.body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == canary)
        #expect(form["client_id"] == "client-123")
        #expect(form["redirect_uri"] == handshake.redirectURI)
        #expect(form["resource"] == "https://mcp.upwork.com/mcp")
        #expect(form["client_secret"] == nil)
        let verifier = try #require(form["code_verifier"])
        #expect(PKCE.challenge(for: verifier) == challenge)
        #expect(grant.issuer == "https://mcp.upwork.com")
        #expect(grant.tokenEndpoint.absoluteString == "https://www.upwork.com/api/v3/oauth2/token")
        #expect(grant.accessToken.reveal() == accessToken)
        #expect(!handshake.isPending)
    }

    @Test func handsTheTokensToTheGatewayWithTheDocumentedShape() async throws {
        let rpc = PasteGatewayRPC()
        let native = McpNativeSignIn(flow: pastedFlow(UpworkLikeServer()), rpc: rpc)
        let session = try await native.beginPaste()
        let state = try #require(query(session.authorizeURL)["state"])
        let redirect = try #require(query(session.authorizeURL)["redirect_uri"])
        let outcome = await session.submit("\(redirect)?code=\(canary)&state=\(state)")
        #expect(outcome == .signedIn)
        #expect(rpc.calls.count == 1)
        let call = try #require(rpc.calls.first)
        #expect(call.0 == "auth.submit_oauth_tokens")
        let params = call.1
        #expect(params["service"]?.stringValue == "mcp:upwork")
        #expect(params["client_id"]?.stringValue == "client-123")
        #expect(params["redirect_uri"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(params["token_endpoint"]?.stringValue == "https://www.upwork.com/api/v3/oauth2/token")
        #expect(params["issuer"]?.stringValue == "https://mcp.upwork.com")
        #expect(params["access_token"]?.stringValue == accessToken)
        #expect(params["refresh_token"]?.stringValue == refreshToken)
        #expect(params["expires_in"]?.intValue == 3600)
        #expect(params["scope"] == nil)
    }

    @Test func aWrongStateIsRejectedAndBurnsTheHandshake() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        await #expect(throws: McpOAuthError.pasted(.stateMismatch)) {
            _ = try await flow.complete(handshake, pasted: answer(handshake, state: "forged"))
        }
        #expect(!handshake.isPending)
        await #expect(throws: McpOAuthError.handshakeUsed) {
            _ = try await flow.complete(handshake, pasted: answer(handshake))
        }
        #expect(server.requests(to: "/api/v3/oauth2/token").isEmpty)
    }

    @Test func aFormatSlipKeepsTheHandshakeSoTheOwnerCanPasteAgain() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        await #expect(throws: McpOAuthError.pasted(.malformed)) {
            _ = try await flow.complete(handshake, pasted: "just some words")
        }
        #expect(handshake.isPending)
        let grant = try await flow.complete(handshake, pasted: answer(handshake))
        #expect(grant.accessToken.reveal() == accessToken)
        #expect(server.requests(to: "/api/v3/oauth2/token").count == 1)
    }

    @Test func aSecondPasteAfterSuccessIsRejectedWithoutAnotherTokenRequest() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        _ = try await flow.complete(handshake, pasted: answer(handshake))
        await #expect(throws: McpOAuthError.handshakeUsed) {
            _ = try await flow.complete(handshake, pasted: answer(handshake))
        }
        #expect(server.requests(to: "/api/v3/oauth2/token").count == 1)
    }

    @Test func aSecondPasteAfterAFailedExchangeIsRejectedWithoutAnotherTokenRequest() async throws {
        let server = UpworkLikeServer()
        server.tokenStatus = 400
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        await #expect(throws: McpOAuthError.tokenExchangeFailed) {
            _ = try await flow.complete(handshake, pasted: answer(handshake))
        }
        await #expect(throws: McpOAuthError.handshakeUsed) {
            _ = try await flow.complete(handshake, pasted: answer(handshake))
        }
        #expect(server.requests(to: "/api/v3/oauth2/token").count == 1)
    }

    @Test func aDeniedAnswerEndsTheHandshake() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        let state = try #require(query(handshake.authorizeURL)["state"])
        await #expect(throws: McpOAuthError.pasted(.denied)) {
            _ = try await flow.complete(handshake, pasted: "\(handshake.redirectURI)?error=access_denied&state=\(state)")
        }
        #expect(!handshake.isPending)
        #expect(server.requests(to: "/api/v3/oauth2/token").isEmpty)
    }

    @Test func cancelClearsTheVerifier() async throws {
        let server = UpworkLikeServer()
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        handshake.cancel()
        #expect(!handshake.isPending)
        await #expect(throws: McpOAuthError.handshakeUsed) {
            _ = try await flow.complete(handshake, pasted: answer(handshake))
        }
        #expect(server.requests(to: "/api/v3/oauth2/token").isEmpty)
    }

    @Test func eachBeginUsesFreshStateAndChallenge() async throws {
        let flow = pastedFlow(UpworkLikeServer())
        let first = query(try await flow.beginPasted().authorizeURL)
        let second = query(try await flow.beginPasted().authorizeURL)
        #expect(first["state"] != second["state"])
        #expect(first["code_challenge"] != second["code_challenge"])
    }

    @Test func theSessionRollsBackOnceOnFailureOrCancelAndNeverAfterSuccess() async throws {
        let failing = UpworkLikeServer()
        failing.tokenStatus = 400
        let counter = RollbackCounter()
        let native = McpNativeSignIn(flow: pastedFlow(failing), rpc: PasteGatewayRPC())
        let session = try await native.beginPaste(rollback: { counter.bump() })
        let tryAgain = await session.submit("nonsense")
        #expect(tryAgain == .tryAgain(PasteError.malformed.userText))
        #expect(counter.value == 0)
        let state = try #require(query(session.authorizeURL)["state"])
        let redirect = try #require(query(session.authorizeURL)["redirect_uri"])
        let failed = await session.submit("\(redirect)?code=\(canary)&state=\(state)")
        #expect(failed == .failed(McpOAuthError.tokenExchangeFailed.reason))
        await session.cancel()
        #expect(counter.value == 1)

        let counter2 = RollbackCounter()
        let ok = McpNativeSignIn(flow: pastedFlow(UpworkLikeServer()), rpc: PasteGatewayRPC())
        let second = try await ok.beginPaste(rollback: { counter2.bump() })
        let secondState = try #require(query(second.authorizeURL)["state"])
        let secondRedirect = try #require(query(second.authorizeURL)["redirect_uri"])
        let signedIn = await second.submit("\(secondRedirect)?code=\(canary)&state=\(secondState)")
        #expect(signedIn == .signedIn)
        await second.cancel()
        #expect(counter2.value == 0)
    }

    @Test func theCodeNeverAppearsInErrorsOrDescriptions() async throws {
        let server = UpworkLikeServer()
        server.tokenStatus = 400
        let flow = pastedFlow(server)
        let handshake = try await flow.beginPasted()
        let state = try #require(query(handshake.authorizeURL)["state"])
        var texts = allDescriptions(of: handshake)
        for input in ["code=\(canary)&state=forged", "code=\(canary)&code=\(canary)&state=\(state)", "\(canary) \(state)"] {
            let fresh = try await flow.beginPasted()
            do {
                _ = try await flow.complete(fresh, pasted: input)
                Issue.record("expected a failure")
            } catch {
                texts += allDescriptions(of: error) + [(error as? McpOAuthError)?.reason ?? ""]
            }
            texts += allDescriptions(of: fresh)
        }
        do {
            _ = try await flow.complete(handshake, pasted: "\(handshake.redirectURI)?code=\(canary)&state=\(state)")
            Issue.record("expected the server to refuse")
        } catch {
            texts += allDescriptions(of: error) + [(error as? McpOAuthError)?.reason ?? ""]
        }
        texts += allDescriptions(of: handshake)
        for text in texts {
            #expect(!text.contains(canary))
            #expect(!text.contains(state))
            #expect(!text.contains(accessToken))
        }
    }

    @Test func theSessionAndOutcomesNeverRevealTheCode() async throws {
        let native = McpNativeSignIn(flow: pastedFlow(UpworkLikeServer()), rpc: PasteGatewayRPC())
        let session = try await native.beginPaste()
        let state = try #require(query(session.authorizeURL)["state"])
        let redirect = try #require(query(session.authorizeURL)["redirect_uri"])
        let outcome = await session.submit("\(redirect)?code=\(canary)&state=forged")
        var texts = allDescriptions(of: session) + allDescriptions(of: outcome)
        texts.append(String(describing: outcome))
        for text in texts {
            #expect(!text.contains(canary))
            #expect(!text.contains(state))
        }
        #expect(outcome == .failed(PasteError.stateMismatch.userText))
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    private(set) var changeCount = 1
    private(set) var cleared = 0

    func copy() { changeCount += 1 }

    func clear() {
        cleared += 1
        changeCount += 1
    }
}

@MainActor
@Suite("Clipboard scrub after paste")
struct PasteboardScrubTests {
    @Test func clearsWhenNothingElseWasCopiedSinceThePaste() {
        let board = FakePasteboard()
        board.copy()
        let scrub = PasteboardScrub(board)
        let mark = scrub.mark()
        #expect(scrub.clear(ifUnchangedSince: mark))
        #expect(board.cleared == 1)
    }

    @Test func leavesAnythingCopiedAfterThePaste() {
        let board = FakePasteboard()
        board.copy()
        let scrub = PasteboardScrub(board)
        let mark = scrub.mark()
        board.copy()
        #expect(!scrub.clear(ifUnchangedSince: mark))
        #expect(board.cleared == 0)
    }

    @Test func aSecondClearAfterTheFirstDoesNothing() {
        let board = FakePasteboard()
        let scrub = PasteboardScrub(board)
        let mark = scrub.mark()
        #expect(scrub.clear(ifUnchangedSince: mark))
        #expect(!scrub.clear(ifUnchangedSince: mark))
        #expect(board.cleared == 1)
    }
}
