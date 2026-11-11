import Foundation
import PalDiagnostics
import PalREST

public struct RestoredIdentity: Sendable, Equatable {
    public let baseURL: GatewayBaseURL
    public let userID: String?
}

public actor AuthSession: AccessTokenProvider {
    public nonisolated let restoredIdentity: RestoredIdentity?
    private let store: any CredentialStore
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private let deviceID: String?
    private var credentials: StoredCredentials?
    private var inflightRefresh: Task<TokenSet, any Error>?

    public init(
        store: any CredentialStore,
        transport: any HTTPTransport,
        diagnostics: Diagnostics = .silent,
        refreshLeeway: TimeInterval = 60,
        deviceID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.store = store
        self.transport = transport
        self.diagnostics = diagnostics
        self.refreshLeeway = refreshLeeway
        self.deviceID = deviceID
        self.now = now
        let loaded = try store.load()
        self.credentials = loaded
        restoredIdentity = loaded.map { RestoredIdentity(baseURL: $0.baseURL, userID: $0.tokens.userID) }
    }

    public var baseURL: GatewayBaseURL? { credentials?.baseURL }
    public var isSignedIn: Bool { credentials != nil }
    public var userID: String? { credentials?.tokens.userID }

    public func adopt(_ newCredentials: StoredCredentials) throws {
        credentials = newCredentials
        try store.save(newCredentials)
    }

    public func signOut() throws {
        inflightRefresh?.cancel()
        inflightRefresh = nil
        credentials = nil
        try store.clear()
    }

    public func accessToken() async throws -> String {
        guard let current = credentials else { throw SignInError.notSignedIn }
        if current.tokens.isExpired(at: now(), leeway: refreshLeeway) {
            return try await refresh().accessToken
        }
        return current.tokens.accessToken
    }

    public func refreshAccessToken(rejecting rejected: String) async throws -> String {
        guard let current = credentials else { throw SignInError.notSignedIn }
        if current.tokens.accessToken != rejected { return current.tokens.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> TokenSet {
        if let inflightRefresh { return try await inflightRefresh.value }
        guard let current = credentials else { throw SignInError.notSignedIn }
        let api = NativeAuthAPI(baseURL: current.baseURL, transport: transport, diagnostics: diagnostics, now: now, deviceID: deviceID)
        let refreshToken = current.tokens.refreshToken
        let provider = current.tokens.provider
        let task = Task { try await api.refresh(refreshToken: refreshToken, provider: provider) }
        inflightRefresh = task
        diagnostics.info("auth", "refreshing access token")
        do {
            let tokens = try await task.value
            if inflightRefresh == task { inflightRefresh = nil }
            guard var latest = credentials else { throw SignInError.notSignedIn }
            guard latest.baseURL == current.baseURL, latest.tokens.refreshToken == refreshToken else {
                diagnostics.info("auth", "refresh result discarded; credentials changed meanwhile")
                return latest.tokens
            }
            latest.tokens = tokens
            credentials = latest
            try store.save(latest)
            diagnostics.info("auth", "access token refreshed")
            return tokens
        } catch {
            if inflightRefresh == task { inflightRefresh = nil }
            if case SignInError.sessionExpired = error, let latest = credentials {
                if latest.baseURL == current.baseURL, latest.tokens.refreshToken == refreshToken {
                    diagnostics.warning("auth", "refresh rejected; signing out")
                    credentials = nil
                    try? store.clear()
                } else {
                    diagnostics.info("auth", "refresh rejection ignored; credentials changed meanwhile")
                    return latest.tokens
                }
            }
            throw error
        }
    }
}
