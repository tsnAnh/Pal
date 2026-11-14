import Foundation
import PalAuth
import PalProtocol
import Synchronization

public struct T3Token: Sendable, Equatable {
    public let access: SecretString
    public let expiresAt: Date?

    public init(access: SecretString, expiresAt: Date?) {
        self.access = access
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

public protocol T3TokenStore: Sendable {
    func load() throws -> T3Token?
    func save(_ token: T3Token) throws
    func clear() throws
}

public struct KeychainT3TokenStore: T3TokenStore {
    private struct Stored: Codable {
        var accessToken: String
        var expiresAt: Date?
    }

    private let item: KeychainItem

    public init(service: String = "dev.tsnanh.hermes.bot.t3code", account: String = "mcp") {
        item = KeychainItem(service: service, account: account)
    }

    public func load() throws -> T3Token? {
        guard let data = try item.read() else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.accessToken.isEmpty else {
            throw KeychainError.corruptItem
        }
        return T3Token(access: SecretString(stored.accessToken), expiresAt: stored.expiresAt)
    }

    public func save(_ token: T3Token) throws {
        try item.write(try JSONEncoder().encode(Stored(accessToken: token.access.reveal(), expiresAt: token.expiresAt)))
    }

    public func clear() throws {
        try item.delete()
    }
}

public final class InMemoryT3TokenStore: T3TokenStore {
    private let value: Mutex<T3Token?>

    public init(_ initial: T3Token? = nil) {
        value = Mutex(initial)
    }

    public func load() throws -> T3Token? { value.withLock { $0 } }
    public func save(_ token: T3Token) throws { value.withLock { $0 = token } }
    public func clear() throws { value.withLock { $0 = nil } }
}
