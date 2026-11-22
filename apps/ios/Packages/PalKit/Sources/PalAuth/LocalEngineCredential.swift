import Foundation
import PalREST

public enum LocalTokenError: Error, Sendable, Equatable {
    case missing
    case unreadable
    case malformed
    case unsafe
}

public struct LocalToken: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let lengthRange = 32...256

    private let value: String

    public init?(validating raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.lengthRange.contains(trimmed.utf8.count), trimmed.utf8.allSatisfy(Self.isURLSafe) else { return nil }
        value = trimmed
    }

    public func reveal() -> String { value }

    public var description: String { "LocalToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    private static func isURLSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"): true
        default: false
        }
    }
}

public struct LocalSessionTokenFile: Sendable, Equatable {
    public let url: URL

    public init(home: URL) {
        url = home.appending(path: "webapp", directoryHint: .isDirectory).appending(path: "session-token", directoryHint: .notDirectory)
    }

    public func read() throws(LocalTokenError) -> LocalToken {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { throw .missing }
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { throw .unreadable }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard owner == getuid(), mode & 0o077 == 0 else { throw .unsafe }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw .unreadable }
        guard let token = LocalToken(validating: text) else { throw .malformed }
        return token
    }
}

public enum LocalEngineCredential {
    public static let provider = "local-engine"
    public static let host = "127.0.0.1"

    public static func baseURL(port: Int) throws -> GatewayBaseURL {
        try GatewayBaseURL(validating: "http://\(host):\(port)")
    }

    public static func credentials(port: Int, home: URL) throws -> StoredCredentials {
        StoredCredentials(
            baseURL: try baseURL(port: port),
            tokens: TokenSet(accessToken: "", refreshToken: "", expiresAt: .distantFuture, provider: provider, userID: nil),
            localHome: home.path
        )
    }
}

public extension StoredCredentials {
    var isLocalEngine: Bool { localHome != nil }
}

public enum KeychainNamespace {
    public static let argument = "-hermes-keychain-namespace"

    public static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
        #else
        return nil
        #endif
    }

    public static func qualified(_ service: String, namespace: String? = KeychainNamespace.current()) -> String {
        namespace.map { "\(service).\($0)" } ?? service
    }
}
