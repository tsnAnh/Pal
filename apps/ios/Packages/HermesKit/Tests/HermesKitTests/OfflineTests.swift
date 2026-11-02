import Foundation
import HermesAuth
import HermesProtocol
import HermesREST
import Testing

@Suite("Base URL validation")
struct BaseURLTests {
    @Test(arguments: [
        "https://hermes.tailnet.ts.net",
        "https://hermes.tailnet.ts.net/",
        "HTTPS://Hermes.Tailnet.ts.net/hermes/",
        "http://127.0.0.1:18791",
        "http://localhost:9120",
    ])
    func accepts(input: String) throws {
        let url = try GatewayBaseURL(validating: input)
        #expect(!url.displayString.hasSuffix("/"))
    }

    @Test(arguments: [
        ("http://hermes.tailnet.ts.net", GatewayBaseURLError.insecureScheme),
        ("http://192.168.1.10:9120", GatewayBaseURLError.insecureScheme),
        ("ftp://hermes.example.com", GatewayBaseURLError.unsupportedScheme),
        ("https://user:pw@hermes.example.com", GatewayBaseURLError.credentialsNotAllowed),
        ("https://hermes.example.com?x=1", GatewayBaseURLError.queryOrFragmentNotAllowed),
        ("https://hermes.example.com#frag", GatewayBaseURLError.queryOrFragmentNotAllowed),
        ("", GatewayBaseURLError.empty),
        ("   ", GatewayBaseURLError.empty),
        ("hermes.example.com", GatewayBaseURLError.malformed),
    ])
    func rejects(input: String, expected: GatewayBaseURLError) {
        #expect(throws: expected) { try GatewayBaseURL(validating: input) }
    }

    @Test func endpointsPreserveSubPath() throws {
        let url = try GatewayBaseURL(validating: "https://example.com/hermes")
        #expect(url.endpoint("/api/ws").absoluteString == "https://example.com/hermes/api/ws")
        #expect(url.webSocketEndpoint("/api/ws").absoluteString == "wss://example.com/hermes/api/ws")
        let local = try GatewayBaseURL(validating: "http://127.0.0.1:1")
        #expect(local.webSocketEndpoint("/api/ws").scheme == "ws")
    }
}

@Suite("JSON-RPC framing")
struct RPCCodecTests {
    @Test func requestRoundTripsAsSingleObject() throws {
        let data = try RPCCodec.encode(RPCRequest(id: .int(7), method: "session.list", params: ["limit": 5]))
        let message = try RPCCodec.decode(data)
        #expect(message == .request(RPCRequest(id: .int(7), method: "session.list", params: ["limit": 5])))
        #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
    }

    @Test func decodesNotificationsAndErrors() throws {
        let event = Data(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"a":1}}}"#.utf8)
        guard case .notification(let notification) = try RPCCodec.decode(event) else { Issue.record("not a notification"); return }
        #expect(GatewayEvent(notification: notification)?.type == "gateway.ready")
        let failure = Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"nope"}}"#.utf8)
        #expect(try RPCCodec.decode(failure) == .response(RPCResponse(id: .int(3), error: RPCError(code: -32601, message: "nope"))))
    }

    @Test func rejectsBatchesWrongVersionAndGarbage() {
        #expect(throws: RPCCodecError.batchUnsupported) { try RPCCodec.decode(Data("[]".utf8)) }
        #expect(throws: RPCCodecError.wrongVersion) { try RPCCodec.decode(Data(#"{"jsonrpc":"1.0","id":1,"result":1}"#.utf8)) }
        #expect(throws: RPCCodecError.malformed) { try RPCCodec.decode(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try RPCCodec.decode(Data("nope".utf8)) }
    }

    @Test func jsonValuePreservesIntegersAndNesting() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":3,"d":1.5,"l":[true,null,"x"]}"#.utf8))
        #expect(value["n"]?.intValue == 3)
        #expect(value["d"] == .double(1.5))
        #expect(value["l"]?[2]?.stringValue == "x")
    }
}

@Suite("PKCE")
struct PKCETests {
    @Test func challengeMatchesRFC7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAreLongAndUnique() throws {
        let a = try PKCE.generate()
        let b = try PKCE.generate()
        #expect(a.verifier.count >= 43 && a.verifier != b.verifier)
    }
}

@Suite("Loopback redirect listener")
struct LoopbackListenerTests {
    @Test func capturesCallbackThenClosesThePort() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10))
        let url = URL(string: "\(listener.redirectURI)?code=abc&state=xyz")!
        async let parameters = listener.awaitCallback()
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await parameters == ["code": "abc", "state": "xyz"])
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: url) }
    }

    @Test func ignoresOtherPathsAndHosts() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10))
        defer { listener.cancel() }
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        var spoofed = URLRequest(url: URL(string: "\(listener.redirectURI)?code=a&state=b")!)
        spoofed.setValue("evil.example.com", forHTTPHeaderField: "Host")
        let (_, spoofedResponse) = try await URLSession.shared.data(for: spoofed)
        #expect((spoofedResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func timesOut() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .milliseconds(200))
        await #expect(throws: SignInError.listenerTimedOut) { _ = try await listener.awaitCallback() }
    }

    @Test func cancelFailsWaiter() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10))
        let waiter = Task { try await listener.awaitCallback() }
        try await Task.sleep(for: .milliseconds(100))
        listener.cancel()
        await #expect(throws: SignInError.cancelled) { _ = try await waiter.value }
    }
}

@Suite("Credential store")
struct CredentialStoreTests {
    @Test func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "dev.tsnanh.hermes.bot.tests.\(UUID().uuidString)")
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let credentials = StoredCredentials(
            baseURL: try GatewayBaseURL(validating: "https://example.com"),
            tokens: TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), provider: "basic", userID: "u")
        )
        try store.save(credentials)
        #expect(try store.load() == credentials)
        var rotated = credentials
        rotated.tokens.accessToken = "a2"
        try store.save(rotated)
        #expect(try store.load() == rotated)
        try store.clear()
        #expect(try store.load() == nil)
    }
}
