import Foundation
import HermesProtocol

public struct BotMeta: Sendable, Equatable {
    public static let namespace = "hermes-bots"

    public var fields: [String: JSONValue]
    public var revision: Int?

    public init(fields: [String: JSONValue] = [:], revision: Int? = nil) {
        self.fields = fields
        self.revision = revision
    }

    init(row: ProfileRowWire) {
        fields = row.uiMeta?[Self.namespace]?.objectValue ?? [:]
        revision = row.uiMetaRevisions?[Self.namespace]
    }

    public var title: String? {
        fields["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var shape: String? {
        fields["shape"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var color: String? {
        fields["color"]?.stringValue
    }
}

public struct BotProfile: Sendable, Equatable {
    public var name: String
    public var displayName: String
    public var isPrimary: Bool
    public var routinesEnabled: Int
    public var meta: BotMeta

    public init(name: String, displayName: String, isPrimary: Bool, routinesEnabled: Int, meta: BotMeta) {
        self.name = name
        self.displayName = displayName
        self.isPrimary = isPrimary
        self.routinesEnabled = routinesEnabled
        self.meta = meta
    }

    init(row: ProfileRowWire) {
        let meta = BotMeta(row: row)
        name = row.name
        displayName = meta.title ?? Self.label(row)
        isPrimary = row.isPrimary ?? false
        routinesEnabled = row.routinesEnabled ?? 0
        self.meta = meta
    }

    private static func label(_ row: ProfileRowWire) -> String {
        if let display = row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        if row.name.lowercased() == "default" { return "Hermes" }
        return row.name
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public struct TemplateFile: Sendable, Equatable {
    public var filename: String
    public var data: Data
}

public enum ComputerStatus: Sendable, Equatable {
    case idle
    case running
    case inUse
    case notSetUp
    case unavailable

    public init(_ wire: DisplayStatusWire) {
        if !wire.supported {
            self = .unavailable
        } else if !wire.installed {
            self = .notSetUp
        } else if wire.running {
            self = wire.lease?.holder == "human" ? .inUse : .running
        } else {
            self = .idle
        }
    }

    public var text: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .running: String(localized: "Running")
        case .inUse: String(localized: "In use")
        case .notSetUp: String(localized: "Not set up")
        case .unavailable: String(localized: "Unavailable")
        }
    }
}
