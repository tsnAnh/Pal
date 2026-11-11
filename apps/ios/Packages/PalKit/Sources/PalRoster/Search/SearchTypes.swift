import Foundation

public enum SearchScope: String, CaseIterable, Sendable, Hashable {
    case all
    case messages
    case bots
    case groupChats
    case files
    case routines

    public var sources: [SearchScope] {
        switch self {
        case .all: [.bots, .messages, .groupChats, .files, .routines]
        default: [self]
        }
    }
}

public struct SearchBot: Sendable, Hashable {
    public var name: String
    public var displayName: String
    public var sessionIDs: Set<String>

    public init(name: String, displayName: String, sessionIDs: Set<String> = []) {
        self.name = name
        self.displayName = displayName
        self.sessionIDs = sessionIDs
    }
}

public enum SearchDestination: Sendable, Hashable {
    case chat(botName: String)
    case groupChat(roomID: String)
    case file(botName: String, itemID: String)
    case routine(botName: String, jobID: String)
}

public struct BotHit: Sendable, Hashable {
    public var botName: String
    public var displayName: String
}

public struct MessageHit: Sendable, Hashable {
    public var botName: String
    public var botDisplayName: String
    public var sessionID: String
    public var title: String?
    public var snippet: String
    public var role: String?
    public var timestamp: Date?
}

public struct GroupHit: Sendable, Hashable {
    public var roomID: String
    public var name: String
    public var memberNames: [String]
    public var updatedAt: Date?
}

public struct FileHit: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case link
        case media
        case file
        case other
    }

    public var botName: String
    public var botDisplayName: String
    public var itemID: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var url: String?
    public var assetRef: String?
    public var mime: String?
    public var size: Int?
    public var sessionID: String
    public var occurredAt: Date?
}

public struct RoutineHit: Sendable, Hashable {
    public var botName: String
    public var botDisplayName: String
    public var jobID: String
    public var name: String
    public var schedule: String
    public var promptPreview: String
    public var isEnabled: Bool
    public var nextRunAt: Date?
}

public enum SearchItem: Sendable, Hashable, Identifiable {
    case bot(BotHit)
    case message(MessageHit)
    case groupChat(GroupHit)
    case file(FileHit)
    case routine(RoutineHit)

    public var scope: SearchScope {
        switch self {
        case .bot: .bots
        case .message: .messages
        case .groupChat: .groupChats
        case .file: .files
        case .routine: .routines
        }
    }

    public var id: String {
        switch self {
        case .bot(let hit): "bot:\(hit.botName)"
        case .message(let hit): "message:\(hit.botName):\(hit.sessionID):\(hit.timestamp?.timeIntervalSince1970 ?? 0):\(hit.snippet.hashValue)"
        case .groupChat(let hit): "group:\(hit.roomID)"
        case .file(let hit): "file:\(hit.botName):\(hit.itemID)"
        case .routine(let hit): "routine:\(hit.botName):\(hit.jobID)"
        }
    }

    public var destination: SearchDestination {
        switch self {
        case .bot(let hit): .chat(botName: hit.botName)
        case .message(let hit): .chat(botName: hit.botName)
        case .groupChat(let hit): .groupChat(roomID: hit.roomID)
        case .file(let hit): .file(botName: hit.botName, itemID: hit.itemID)
        case .routine(let hit): .routine(botName: hit.botName, jobID: hit.jobID)
        }
    }
}

public struct SourceState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    public var phase: Phase
    public var items: [SearchItem]
    public var isIncomplete: Bool

    public init(phase: Phase = .idle, items: [SearchItem] = [], isIncomplete: Bool = false) {
        self.phase = phase
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

public struct SearchState: Sendable, Equatable {
    public var query: String
    public var sources: [SearchScope: SourceState]

    public init(query: String = "", sources: [SearchScope: SourceState] = [:]) {
        self.query = query
        self.sources = sources
    }

    public func state(of source: SearchScope) -> SourceState {
        sources[source] ?? SourceState()
    }

    public func items(for scope: SearchScope) -> [SearchItem] {
        scope.sources.flatMap { state(of: $0).items }
    }

    public func isLoading(_ scope: SearchScope) -> Bool {
        scope.sources.contains { state(of: $0).phase == .loading }
    }

    public func failedSources(in scope: SearchScope) -> [SearchScope] {
        scope.sources.filter { state(of: $0).phase == .failed }
    }
}
