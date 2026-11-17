import Foundation
import PalTransport

public struct KanbanBoardKey: Sendable, Hashable {
    public let gatewayID: String
    public let board: String

    public init(gatewayID: String, board: String) {
        self.gatewayID = gatewayID
        self.board = board
    }
}

public struct KanbanCardKey: Sendable, Hashable {
    public let board: KanbanBoardKey
    public let taskID: String

    public init(board: KanbanBoardKey, taskID: String) {
        self.board = board
        self.taskID = taskID
    }
}

public struct KanbanBoardCache: Sendable, Equatable, Codable {
    public var board: KanbanBoard?
    public var cards: [String: KanbanCard]
    public var prerequisites: Set<KanbanPrerequisite>
    public var cursor: String?
    public var highWater: Int
    public var generation: Int
    public var events: [KanbanEvent]

    public static let eventLimit = 500

    public var sortedCards: [KanbanCard] {
        cards.values.sorted { ($0.createdAt ?? 0, $0.taskID) < ($1.createdAt ?? 0, $1.taskID) }
    }
}

public struct KanbanSnapshotStaging: Sendable {
    public enum Step: Sendable, Equatable {
        case more(String)
        case complete(cursor: String)
        case restart(reason: String)
        case unavailable(KanbanReadState)
    }

    public private(set) var gatewayID: String?
    public private(set) var board: KanbanBoard?
    public private(set) var cards: [String: KanbanCard] = [:]
    public private(set) var prerequisites: Set<KanbanPrerequisite> = []
    private var seenTokens: Set<String> = []

    public init() {}

    public mutating func absorb(_ page: KanbanSnapshotPage, board slug: String) -> Step {
        if page.scope.board != slug { return .restart(reason: "wrong_board") }
        if let gatewayID, gatewayID != page.scope.gatewayID { return .restart(reason: "wrong_gateway") }
        gatewayID = page.scope.gatewayID
        switch page.state {
        case .snapshotRequired:
            return .restart(reason: page.reason ?? "snapshot_required")
        case .present:
            break
        default:
            return .unavailable(page.state)
        }
        for card in page.cards { cards[card.cardID] = card }
        prerequisites.formUnion(page.prerequisites)
        board = page.board ?? board
        if let token = page.nextPageToken {
            guard seenTokens.insert(token).inserted else { return .restart(reason: "repeated_page_token") }
            return .more(token)
        }
        guard let cursor = page.cursor else { return .restart(reason: "cursor_missing") }
        return .complete(cursor: cursor)
    }
}

public struct KanbanEventApplication: Sendable, Equatable {
    public let advanced: Bool
    public let affectedTaskIDs: [String]
}

public struct KanbanSession: Sendable, Equatable {
    public private(set) var gatewayID: String?
    public private(set) var boards: [KanbanBoard] = []
    public private(set) var caches: [KanbanBoardKey: KanbanBoardCache] = [:]
    public private(set) var details: [KanbanCardKey: KanbanCardDetail] = [:]

    public init() {}

    public func boardKey(_ board: String) -> KanbanBoardKey? {
        gatewayID.map { KanbanBoardKey(gatewayID: $0, board: board) }
    }

    public func cache(_ board: String) -> KanbanBoardCache? {
        boardKey(board).flatMap { caches[$0] }
    }

    public func detail(board: String, taskID: String) -> KanbanCardDetail? {
        boardKey(board).flatMap { details[KanbanCardKey(board: $0, taskID: taskID)] }
    }

    @discardableResult
    public mutating func adopt(gatewayID id: String) -> Bool {
        guard let held = gatewayID, held != id else {
            gatewayID = id
            return false
        }
        dropAll()
        gatewayID = id
        return true
    }

    public mutating func dropAll() {
        gatewayID = nil
        boards = []
        caches = [:]
        details = [:]
    }

    public mutating func setBoards(_ boards: [KanbanBoard]) {
        self.boards = boards
    }

    public mutating func publish(_ staging: KanbanSnapshotStaging, cursor: String, board: String) {
        guard let gatewayID = staging.gatewayID, gatewayID == self.gatewayID else { return }
        let key = KanbanBoardKey(gatewayID: gatewayID, board: board)
        let held = caches[key]
        let unchanged = held.map { $0.board == staging.board && $0.cards == staging.cards && $0.prerequisites == staging.prerequisites } ?? false
        let generation = (held?.generation ?? 0) + (unchanged ? 0 : 1)
        caches[key] = KanbanBoardCache(
            board: staging.board, cards: staging.cards, prerequisites: staging.prerequisites,
            cursor: cursor, highWater: 0, generation: generation, events: []
        )
        let tasks = Set(staging.cards.values.map(\.taskID))
        details = details.filter { $0.key.board != key || tasks.contains($0.key.taskID) }
    }

    public mutating func restore(_ saved: KanbanSavedBoard, board: String) {
        guard gatewayID == nil || gatewayID == saved.gatewayID else { return }
        gatewayID = saved.gatewayID
        let key = KanbanBoardKey(gatewayID: saved.gatewayID, board: board)
        guard caches[key] == nil else { return }
        caches[key] = saved.cache
        for detail in saved.details {
            details[KanbanCardKey(board: key, taskID: detail.card.taskID)] = detail
        }
    }

    public func saved(_ board: String, at date: Date) -> KanbanSavedBoard? {
        guard let key = boardKey(board), let cache = caches[key] else { return nil }
        let held = cache.sortedCards.compactMap { details[KanbanCardKey(board: key, taskID: $0.taskID)] }
        return KanbanSavedBoard(
            schema: KanbanSavedBoard.currentSchema, savedAt: date, gatewayID: key.gatewayID,
            cache: cache, details: Array(held.prefix(KanbanSavedBoard.maxDetails))
        )
    }

    public mutating func removeBoard(_ board: String) {
        guard let key = boardKey(board) else { return }
        caches[key] = nil
        details = details.filter { $0.key.board != key }
    }

    public mutating func apply(_ page: KanbanEventsPage, board: String, generation: Int) -> KanbanEventApplication {
        guard let key = boardKey(board), var cache = caches[key], cache.generation == generation else {
            return KanbanEventApplication(advanced: false, affectedTaskIDs: [])
        }
        var seen = Set<Int>()
        let fresh = page.events
            .filter { $0.eventID > cache.highWater && seen.insert($0.eventID).inserted }
            .sorted { $0.eventID < $1.eventID }
        if fresh.isEmpty, !page.events.isEmpty {
            return KanbanEventApplication(advanced: false, affectedTaskIDs: [])
        }
        if let last = fresh.last { cache.highWater = last.eventID }
        cache.events = Array((cache.events + fresh).suffix(KanbanBoardCache.eventLimit))
        if let cursor = page.cursor { cache.cursor = cursor }
        caches[key] = cache
        var ordered: [String] = []
        for event in fresh where !ordered.contains(event.taskID) { ordered.append(event.taskID) }
        return KanbanEventApplication(advanced: true, affectedTaskIDs: ordered)
    }

    public mutating func store(_ result: KanbanCardResult, board: String) {
        guard let key = boardKey(board), result.scope.gatewayID == key.gatewayID else { return }
        guard let detail = result.detail, result.state == .present else { return }
        let taskID = detail.card.taskID
        details[KanbanCardKey(board: key, taskID: taskID)] = detail
        guard var cache = caches[key] else { return }
        cache.cards[detail.card.cardID] = detail.card
        cache.prerequisites = cache.prerequisites.filter { $0.taskID != taskID }
        for required in detail.prerequisites {
            cache.prerequisites.insert(KanbanPrerequisite(taskID: taskID, requiresTaskID: required))
        }
        caches[key] = cache
    }

    public mutating func removeCard(board: String, taskID: String) {
        guard let key = boardKey(board), var cache = caches[key] else { return }
        cache.cards = cache.cards.filter { $0.value.taskID != taskID }
        cache.prerequisites = cache.prerequisites.filter { $0.taskID != taskID && $0.requiresTaskID != taskID }
        caches[key] = cache
        details[KanbanCardKey(board: key, taskID: taskID)] = nil
    }
}

public enum KanbanPollSchedule {
    public static let interval: Duration = .seconds(2)
    public static let ceiling: Duration = .seconds(60)

    public static func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return interval }
        let steps = min(failures, 6)
        return min(interval * (1 << (steps - 1)), ceiling)
    }
}
