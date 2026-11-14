import Foundation
import PalProtocol
import PalRoster

extension BotMeta {
    init(row: ProfileRowWire) {
        self.init(fields: row.uiMeta?[Self.namespace]?.objectValue ?? [:], revision: row.uiMetaRevisions?[Self.namespace])
    }
}

public struct BotProfile: Sendable, Equatable, Codable {
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

    public var isSetupUnfinished: Bool {
        !isPrimary && name.lowercased() != "default" && !meta.hasLook
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
        if row.name.lowercased() == "default" { return "Pal" }
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

public enum ComputerStatus: Sendable, Equatable, Codable {
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
