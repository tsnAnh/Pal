import Foundation
import PalProtocol
import PalTransport

public struct KanbanSavedBoard: Sendable, Equatable, Codable {
    public static let currentSchema = 1
    public static let maxDetails = 200
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public let schema: Int
    public let savedAt: Date
    public let gatewayID: String
    public let cache: KanbanBoardCache
    public let details: [KanbanCardDetail]

    public func isUsable(at date: Date) -> Bool {
        schema == Self.currentSchema && date.timeIntervalSince(savedAt) <= Self.maxAge
    }
}

public struct KanbanDiskCache: Sendable {
    private let store: CacheStore
    private let account: String
    private let now: @Sendable () -> Date

    public init(store: CacheStore, account: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.account = account
        self.now = now
    }

    public static func name(board: String) -> String {
        "kanban-board-\(board)"
    }

    public func load(board: String) async -> KanbanSavedBoard? {
        let name = Self.name(board: board)
        guard let saved = await store.loadDetached(KanbanSavedBoard.self, name: name, account: account) else { return nil }
        guard saved.isUsable(at: now()) else {
            store.remove(name: name, account: account)
            return nil
        }
        return saved
    }

    public func save(_ session: KanbanSession, board: String) {
        guard let saved = session.saved(board, at: now()) else { return }
        store.save(saved, name: Self.name(board: board), account: account)
    }

    public func remove(board: String) {
        store.remove(name: Self.name(board: board), account: account)
    }

    public static let lastBoardName = "kanban-last-board"

    public func lastBoard() async -> String? {
        await store.loadDetached(String.self, name: Self.lastBoardName, account: account)
    }

    public func saveLastBoard(_ board: String) {
        guard !board.isEmpty, board.count <= KanbanBoardChoice.maxSlugLength else { return }
        store.save(board, name: Self.lastBoardName, account: account)
    }
}

public enum KanbanReadiness {
    public static func rows(session: KanbanSession, board: String, settledGeneration: Int?) -> [KanbanCardRow]? {
        guard let cache = session.cache(board) else { return nil }
        let all = KanbanBoardLayout.rows(session: session, board: board)
        if settledGeneration == cache.generation { return all }
        let complete = all.filter(isComplete)
        if complete.count == all.count { return all }
        return settledGeneration == nil ? nil : complete
    }

    public static func isComplete(_ row: KanbanCardRow) -> Bool {
        row.detail != nil
    }

    public static func boardName(session: KanbanSession, board: String) -> String? {
        session.cache(board)?.board?.name ?? session.boards.first { $0.scope.board == board }?.name
    }
}
