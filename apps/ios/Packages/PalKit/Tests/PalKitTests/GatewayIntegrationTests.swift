import Foundation
import PalAuth
import PalClient
import PalDiagnostics
import PalProtocol
import PalREST
import PalTransport
import OSLog
import Testing

@Suite("Live gateway", .serialized, .enabled(if: LiveGateway.isConfigured, "set HERMES_IOS_TEST_* to run against a gateway"))
struct GatewayIntegrationTests {
    let gateway = LiveGateway.fromEnvironment()!
    let recorder = DiagnosticRecorder()
    let transport: RecordingTransport

    init() {
        transport = RecordingTransport()
    }

    private var diagnostics: Diagnostics {
        recorder.diagnostics.combined(with: .osLog(subsystem: Self.subsystem))
    }

    private static let subsystem = "dev.tsnanh.hermes.bot.tests"

    private func signIn(store: any CredentialStore = InMemoryCredentialStore()) async throws -> (AuthSession, ProgrammaticBrowser) {
        let browser = ProgrammaticBrowser(username: gateway.username, password: gateway.password)
        let credentials = try await NativeSignIn(transport: transport, diagnostics: diagnostics)
            .signIn(baseURL: gateway.baseURL, browser: browser)
        let session = try AuthSession(store: store, transport: transport, diagnostics: diagnostics)
        try await session.adopt(credentials)
        return (session, browser)
    }

    @Test func fullSignInDialAndRoundTrips() async throws {
        let store = InMemoryCredentialStore()
        let (session, browser) = try await signIn(store: store)
        #expect(browser.dismissCount >= 1)
        #expect(browser.callbackURL?.host == "127.0.0.1")
        let stored = try #require(try store.load())
        #expect(stored.baseURL == gateway.baseURL)
        #expect(stored.tokens.userID == gateway.username)
        #expect(stored.tokens.expiresAt > Date())

        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        let connection = try await client.connect()
        defer { Task { await connection.close() } }
        try await connection.ping()
        let described = try await client.describeRuntime(on: connection)
        #expect(!described.instanceID.isEmpty)
        let sessions = try await connection.call("session.list", params: [:])
        #expect(sessions.objectValue != nil || sessions.arrayValue != nil)
        print("runtime.describe instance_id=\(described.instanceID) profile=\(described.profileID)")
    }

    @Test func socketTicketsAreOneUse() async throws {
        let (session, _) = try await signIn()
        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        let ticket = try await client.mintSocketTicket()
        #expect(ticket.ttlSeconds > 0)
        let url = gateway.baseURL.webSocketEndpoint("/api/ws")
        let first = try await GatewayConnection.dial(url: url, ticket: ticket.ticket, diagnostics: diagnostics)
        await first.close()
        await #expect(throws: (any Error).self) {
            _ = try await GatewayConnection.dial(url: url, ticket: ticket.ticket, diagnostics: diagnostics)
        }
        let fresh = try await client.connect()
        await fresh.close()
    }

    @Test func eachConnectUsesAFreshTicket() async throws {
        let (session, _) = try await signIn()
        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        let before = transport.count(path: "/api/webapp/socket-ticket")
        for _ in 0..<2 { await (try await client.connect()).close() }
        #expect(transport.count(path: "/api/webapp/socket-ticket") - before == 2)
    }

    @Test func expiredTokenRefreshesOnceAcrossConcurrentCallers() async throws {
        let store = InMemoryCredentialStore()
        let (signedIn, _) = try await signIn(store: store)
        let original = try await signedIn.accessToken()
        let future = Date().addingTimeInterval(24 * 3600)
        let session = try AuthSession(store: store, transport: transport, diagnostics: diagnostics, now: { future })
        let before = transport.count(path: "/auth/native/refresh")
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await session.accessToken() } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(transport.count(path: "/auth/native/refresh") - before == 1)
        #expect(tokens.count == 1)
        #expect(tokens.first != original)
        #expect(try store.load()?.tokens.accessToken == tokens.first)
    }

    @Test func rejectedAccessTokenIsRefreshedAndRetried() async throws {
        let store = InMemoryCredentialStore()
        let (signedIn, _) = try await signIn(store: store)
        var credentials = try #require(try store.load())
        credentials.tokens.accessToken = "rejected-access-token-value"
        try store.save(credentials)
        _ = signedIn
        let session = try AuthSession(store: store, transport: transport, diagnostics: diagnostics)
        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        let before = transport.count(path: "/auth/native/refresh")
        let ticket = try await client.mintSocketTicket()
        #expect(!ticket.ticket.isEmpty)
        #expect(transport.count(path: "/auth/native/refresh") - before == 1)
        #expect(try store.load()?.tokens.accessToken != "rejected-access-token-value")
    }

    @Test func revokedRefreshTokenSignsOut() async throws {
        let store = InMemoryCredentialStore()
        let (_, _) = try await signIn(store: store)
        var credentials = try #require(try store.load())
        credentials.tokens.refreshToken = "not-a-real-refresh-token"
        credentials.tokens.accessToken = "not-a-real-access-token"
        try store.save(credentials)
        let session = try AuthSession(store: store, transport: transport, diagnostics: diagnostics)
        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        await #expect(throws: SignInError.sessionExpired) { _ = try await client.mintSocketTicket() }
        #expect(try store.load() == nil)
        #expect(await session.isSignedIn == false)
    }

    @Test func stateMismatchAbortsBeforeTokenExchange() async throws {
        struct TamperingBrowser: AuthorizationBrowser {
            let inner: ProgrammaticBrowser
            func present(_ url: URL) async throws {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = components.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: "forged") : $0 }
                try await inner.present(components.url!)
            }
            func dismiss() async { await inner.dismiss() }
        }
        let before = transport.count(path: "/auth/native/token")
        let browser = TamperingBrowser(inner: ProgrammaticBrowser(username: gateway.username, password: gateway.password))
        await #expect(throws: SignInError.stateMismatch) {
            _ = try await NativeSignIn(transport: transport, diagnostics: diagnostics).signIn(baseURL: gateway.baseURL, browser: browser)
        }
        #expect(transport.count(path: "/auth/native/token") == before)
    }

    @Test func abandonedBrowserCancelsSignIn() async throws {
        struct ClosingBrowser: AuthorizationBrowser {
            func present(_ url: URL) async throws {}
            func dismiss() async {}
        }
        await #expect(throws: SignInError.cancelled) {
            _ = try await NativeSignIn(transport: transport, diagnostics: diagnostics).signIn(baseURL: gateway.baseURL, browser: ClosingBrowser())
        }
    }

    @Test func noSecretsAppearInDiagnosticsOrSystemLog() async throws {
        let started = Date()
        let (session, _) = try await signIn()
        let client = PalClient(auth: session, transport: transport, diagnostics: diagnostics)
        let connection = try await client.connect()
        _ = try await client.describeRuntime(on: connection)
        await connection.close()
        let future = Date().addingTimeInterval(24 * 3600)
        let refreshing = try AuthSession(
            store: InMemoryCredentialStore(try await StoredCredentials(baseURL: gateway.baseURL, tokens: tokensOf(session))),
            transport: transport,
            diagnostics: diagnostics,
            now: { future }
        )
        _ = try await refreshing.accessToken()

        let secrets = transport.secrets
        #expect(secrets.count >= 5)
        let transcript = recorder.transcript
        #expect(transcript.contains("dialing"))
        #expect(transcript.contains("refreshing access token"))
        for secret in secrets { #expect(!transcript.contains(secret), "diagnostics leaked a secret value") }
        for marker in ["Bearer", "code=", "code_verifier", "ticket=", "?", "hermes-gateway-ticket"] {
            #expect(!transcript.contains(marker), "diagnostics contain \(marker)")
        }

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == Self.subsystem }
        let systemLog = entries.map(\.composedMessage).joined(separator: "\n")
        #expect(!entries.isEmpty)
        for secret in secrets { #expect(!systemLog.contains(secret), "system log leaked a secret value") }
        for marker in ["Bearer", "code=", "code_verifier", "ticket=", "hermes-gateway-ticket"] {
            #expect(!systemLog.contains(marker), "system log contains \(marker)")
        }
    }

    private func tokensOf(_ session: AuthSession) async throws -> TokenSet {
        let access = try await session.accessToken()
        let exchange = try #require(transport.exchanges.last { $0.url.path == "/auth/native/token" })
        let object = try #require(try JSONSerialization.jsonObject(with: exchange.responseBody) as? [String: Any])
        return TokenSet(
            accessToken: access,
            refreshToken: try #require(object["refresh_token"] as? String),
            expiresAt: Date().addingTimeInterval(3600),
            provider: object["provider"] as? String
        )
    }
}
