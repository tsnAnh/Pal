import Foundation

public struct TailnetStatus: Sendable, Equatable, Decodable {
    public let enabled: Bool
    public let url: String?
    public let username: String?
    public let reachable: Bool?

    public init(enabled: Bool, url: String?, username: String?, reachable: Bool?) {
        self.enabled = enabled
        self.url = url
        self.username = username
        self.reachable = reachable
    }
}

public struct TailnetCredentials: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: String
    public let username: String
    public let password: String
    public let reachable: Bool

    enum CodingKeys: String, CodingKey {
        case url, username, password, reachable
    }

    public init(url: String, username: String, password: String, reachable: Bool) {
        self.url = url
        self.username = username
        self.password = password
        self.reachable = reachable
    }

    public var description: String { "TailnetCredentials(url: \(url), username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["url": url, "username": username, "reachable": reachable]) }
}

public struct TailnetError: Error, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

struct TailnetErrorReport: Decodable {
    let error: String
}

enum TailnetOutput {
    static func decode<Value: Decodable>(_ type: Value.Type, lines: [String]) -> Value? {
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(type, from: Data(lines.joined(separator: "\n").utf8)) { return value }
        guard let line = lines.last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? decoder.decode(type, from: Data(line.utf8))
    }
}
