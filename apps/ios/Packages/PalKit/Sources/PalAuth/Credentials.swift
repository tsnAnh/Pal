import Foundation
import PalREST
import Security
import Synchronization

public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var provider: String?
    public var userID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, provider: String? = nil, userID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userID = userID
    }

    struct Payload: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double?
        var provider: String?
        var userID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case provider
            case userID = "user_id"
        }
    }

    init(payload: Payload, now: Date) {
        self.init(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresAt.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(3600),
            provider: payload.provider,
            userID: payload.userID
        )
    }

    public func isExpired(at now: Date, leeway: TimeInterval) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

public struct StoredCredentials: Codable, Sendable, Equatable {
    public var baseURL: GatewayBaseURL
    public var tokens: TokenSet

    public init(baseURL: GatewayBaseURL, tokens: TokenSet) {
        self.baseURL = baseURL
        self.tokens = tokens
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> StoredCredentials?
    func save(_ credentials: StoredCredentials) throws
    func clear() throws
}

public final class InMemoryCredentialStore: CredentialStore {
    private let value = Mutex<StoredCredentials?>(nil)

    public init(_ initial: StoredCredentials? = nil) {
        value.withLock { $0 = initial }
    }

    public func load() throws -> StoredCredentials? { value.withLock { $0 } }
    public func save(_ credentials: StoredCredentials) throws { value.withLock { $0 = credentials } }
    public func clear() throws { value.withLock { $0 = nil } }
}

public enum KeychainError: Error, Sendable, Equatable {
    case status(OSStatus)
    case corruptItem
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.tsnanh.hermes.bot.credentials", account: String = "gateway") {
        self.service = service
        self.account = account
    }

    private var item: KeychainItem { KeychainItem(service: service, account: account) }

    public func load() throws -> StoredCredentials? {
        guard let data = try item.read() else { return nil }
        guard let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data) else { throw KeychainError.corruptItem }
        return credentials
    }

    public func save(_ credentials: StoredCredentials) throws {
        try item.write(try JSONEncoder().encode(credentials))
    }

    public func clear() throws {
        try item.delete()
    }
}
