import Foundation
import PalAuth
import PalREST
import Synchronization
import Testing

private struct ForbiddenTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        Issue.record("a local session must never call the network to refresh: \(request.url?.absoluteString ?? "")")
        throw URLError(.badURL)
    }
}

private final class AnswerByToken: HTTPTransport {
    private let accepted: String
    private let onRequest: @Sendable (Int) -> Void
    private let seen = Mutex<[String?]>([])

    init(accepting accepted: String, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.accepted = accepted
        self.onRequest = onRequest
    }

    var bearers: [String?] { seen.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let header = request.value(forHTTPHeaderField: "Authorization")
        let count = seen.withLock { bearers -> Int in
            bearers.append(header)
            return bearers.count
        }
        onRequest(count)
        let status = header == "Bearer \(accepted)" ? 200 : 401
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return HTTPResult(data: Data("{\"ok\":true}".utf8), response: response)
    }
}

private struct HealthReply: Decodable, Sendable { let ok: Bool }

private final class EngineHome: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "pal-engine-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var tokenFile: URL { LocalSessionTokenFile(home: url).url }

    func writeToken(_ text: String, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tokenFile.path)
    }
}

private func tokenText(_ letter: Character) -> String { String(repeating: letter, count: 43) }

@Suite("Local engine sign-in")
struct LocalEngineCredentialTests {
    @Test func tokensMustMatchWhatTheEngineAccepts() {
        #expect(LocalToken(validating: String(repeating: "a", count: 31)) == nil)
        #expect(LocalToken(validating: String(repeating: "a", count: 32)) != nil)
        #expect(LocalToken(validating: String(repeating: "a", count: 256)) != nil)
        #expect(LocalToken(validating: String(repeating: "a", count: 257)) == nil)
        #expect(LocalToken(validating: String(repeating: "a", count: 31) + "+") == nil)
        #expect(LocalToken(validating: String(repeating: "a", count: 31) + " b") == nil)
        #expect(LocalToken(validating: "  " + String(repeating: "Z", count: 40) + "\n")?.reveal() == String(repeating: "Z", count: 40))
    }

    @Test func theTokenNeverAppearsInDescriptionsOrDumps() throws {
        let secret = "SECRETSECRETSECRETSECRETSECRETSECRET1"
        let value = try #require(LocalToken(validating: secret))
        #expect(!"\(value)".contains(secret))
        #expect(!String(reflecting: value).contains(secret))
        var dumped = ""
        dump(value, to: &dumped)
        #expect(!dumped.contains(secret))
    }

    @Test func theSessionTokenFileIsReadFromTheEnginesWebappFolder() throws {
        let home = try EngineHome()
        #expect(LocalSessionTokenFile(home: home.url).url.path.hasSuffix("/webapp/session-token"))
        try home.writeToken(tokenText("a"))
        #expect(try LocalSessionTokenFile(home: home.url).read().reveal() == tokenText("a"))
    }

    @Test func aMissingMalformedOrSharedTokenFileIsRefusedWithItsReason() throws {
        let home = try EngineHome()
        let file = LocalSessionTokenFile(home: home.url)
        #expect(throws: LocalTokenError.missing) { try file.read() }
        try home.writeToken("short")
        #expect(throws: LocalTokenError.malformed) { try file.read() }
        try home.writeToken(tokenText("a"), mode: 0o644)
        #expect(throws: LocalTokenError.unsafe) { try file.read() }
        try home.writeToken(tokenText("a"), mode: 0o640)
        #expect(throws: LocalTokenError.unsafe) { try file.read() }
        try home.writeToken(tokenText("a"), mode: 0o600)
        #expect(throws: Never.self) { try file.read() }
    }

    @Test func theSavedCredentialHoldsTheHomeAndPortButNeverTheToken() throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("S"))
        let credentials = try LocalEngineCredential.credentials(port: 9123, home: home.url)
        let encoded = try JSONEncoder().encode(credentials)
        #expect(!(String(bytes: encoded, encoding: .utf8) ?? "").contains(tokenText("S")))
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: encoded)
        #expect(decoded == credentials)
        #expect(decoded.isLocalEngine && decoded.localHome == home.url.path)
        #expect(decoded.baseURL.displayString == "http://127.0.0.1:9123")
    }

    @Test func aPasswordSessionIsNotLocalAndStillExpires() throws {
        let normal = StoredCredentials(
            baseURL: try GatewayBaseURL(validating: "https://pal.example.com"),
            tokens: TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0), provider: "password")
        )
        #expect(!normal.isLocalEngine)
        #expect(normal.tokens.isExpired(at: Date(), leeway: 60))
    }

    @Test func theLoopbackAddressIsTheOnlyHostAndThePortIsKept() throws {
        #expect(try LocalEngineCredential.baseURL(port: 9124).displayString == "http://127.0.0.1:9124")
    }
}

@Suite("Local engine session token from the file")
struct LocalEngineSessionTokenTests {
    private func session(_ home: EngineHome, store: InMemoryCredentialStore = InMemoryCredentialStore()) async throws -> AuthSession {
        let session = try AuthSession(store: store, transport: ForbiddenTransport())
        try await session.adopt(LocalEngineCredential.credentials(port: 9123, home: home.url))
        return session
    }

    @Test func everyCallReadsTheFileSoARotatedTokenIsPickedUpWithoutARefresh() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("a"))
        let session = try await session(home)
        #expect(await session.isLocalEngine)
        #expect(try await session.accessToken() == tokenText("a"))
        try home.writeToken(tokenText("b"))
        #expect(try await session.accessToken() == tokenText("b"))
    }

    @Test func anUnreadableFileFailsWithItsOwnReasonAndKeepsTheSession() async throws {
        let home = try EngineHome()
        let session = try await session(home)
        await #expect(throws: SignInError.localTokenUnavailable) { try await session.accessToken() }
        #expect(await session.isSignedIn)
        await #expect(throws: SignInError.localTokenUnavailable) { try await session.refreshAccessToken(rejecting: tokenText("a")) }
        #expect(await session.isSignedIn)
    }

    @Test func aRejectedTokenIsRereadOnceAndAChangedFileWins() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("b"))
        let session = try await session(home)
        #expect(try await session.refreshAccessToken(rejecting: tokenText("a")) == tokenText("b"))
        #expect(await session.isSignedIn)
    }

    @Test func aTokenTheEngineRefusedThatTheFileStillHoldsEndsTheSession() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("a"))
        let store = InMemoryCredentialStore()
        let session = try await session(home, store: store)
        await #expect(throws: SignInError.sessionExpired) { try await session.refreshAccessToken(rejecting: tokenText("a")) }
        #expect(await !session.isSignedIn)
        #expect(try store.load() == nil)
    }

    @Test func aRestoredSessionKnowsItIsLocalBeforeAnyNetworkCall() throws {
        let home = try EngineHome()
        let credentials = try LocalEngineCredential.credentials(port: 9119, home: home.url)
        let session = try AuthSession(store: InMemoryCredentialStore(credentials), transport: ForbiddenTransport())
        #expect(session.restoredIdentity?.isLocalEngine == true)
    }

    @Test func aRestRequestCarriesTheFilesCurrentToken() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("a"))
        let transport = AnswerByToken(accepting: tokenText("a"))
        let auth = try AuthSession(store: InMemoryCredentialStore(), transport: ForbiddenTransport())
        try await auth.adopt(LocalEngineCredential.credentials(port: 9123, home: home.url))
        let rest = RESTClient(baseURL: try LocalEngineCredential.baseURL(port: 9123), transport: transport, tokens: auth)
        let reply: HealthReply = try await rest.get("/api/profiles")
        #expect(reply.ok)
        #expect(transport.bearers == ["Bearer \(tokenText("a"))"])
    }

    @Test func aRequestRefusedBecauseTheTokenRotatedRetriesOnceWithTheNewFile() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("a"))
        let transport = AnswerByToken(accepting: tokenText("b"), onRequest: { count in
            if count == 1 { try? home.writeToken(tokenText("b")) }
        })
        let auth = try AuthSession(store: InMemoryCredentialStore(), transport: ForbiddenTransport())
        try await auth.adopt(LocalEngineCredential.credentials(port: 9123, home: home.url))
        let rest = RESTClient(baseURL: try LocalEngineCredential.baseURL(port: 9123), transport: transport, tokens: auth)
        let reply: HealthReply = try await rest.get("/api/profiles")
        #expect(reply.ok)
        #expect(transport.bearers == ["Bearer \(tokenText("a"))", "Bearer \(tokenText("b"))"])
    }

    @Test func aRestRequestTheEngineKeepsRefusingStopsAfterOneRetryAndSignsOut() async throws {
        let home = try EngineHome()
        try home.writeToken(tokenText("a"))
        let transport = AnswerByToken(accepting: tokenText("z"))
        let auth = try AuthSession(store: InMemoryCredentialStore(), transport: ForbiddenTransport())
        try await auth.adopt(LocalEngineCredential.credentials(port: 9123, home: home.url))
        let rest = RESTClient(baseURL: try LocalEngineCredential.baseURL(port: 9123), transport: transport, tokens: auth)
        await #expect(throws: SignInError.sessionExpired) { let _: HealthReply = try await rest.get("/api/profiles") }
        #expect(transport.bearers == ["Bearer \(tokenText("a"))"])
        #expect(await !auth.isSignedIn)
    }
}
