import Foundation
import Observation
import PalTransport

public enum KanbanLoad: Sendable, Equatable {
    case idle
    case loading
    case ready
    case unsupported
    case permissionDenied
    case boardAbsent
    case boardArchived
    case cardAbsent
    case failed
    case unreachable

    public var message: String? {
        switch self {
        case .unsupported: "This server doesn't offer boards yet."
        case .permissionDenied: "This device isn't allowed to read boards on this server. Ask the server's owner for access."
        case .boardAbsent: "This board isn't on the server anymore."
        case .boardArchived: "This board is archived."
        case .cardAbsent: "This card isn't on the board anymore."
        case .failed: "Couldn't load the board. Retrying shortly."
        case .unreachable: "Can't reach the server. Showing the last update and reconnecting automatically."
        case .idle, .loading, .ready: nil
        }
    }

    static func from(_ failure: KanbanFailure) -> KanbanLoad {
        switch failure {
        case .unsupported: .unsupported
        case .permissionDenied, .profileMismatch: .permissionDenied
        case .unreachable: .unreachable
        default: .failed
        }
    }
}

public struct KanbanFollowTarget: Sendable, Hashable {
    public let board: String?
    public let isActive: Bool

    public init(board: String?, isActive: Bool) {
        self.board = board
        self.isActive = isActive
    }

    public var followedBoard: String? { isActive ? board : nil }
}

public enum KanbanPollStep: Sendable, Equatable {
    case again
    case wait
    case backoff
    case stop
}

@MainActor
@Observable
public final class KanbanStore {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let pageSize = 100
    public static let eventPageSize = 200
    public static let maxSnapshotRestarts = 3
    public static let maxCardRefreshes = 20
    public static let maxPrefetchedCards = 40

    public private(set) var session = KanbanSession()
    public private(set) var boardsLoad: KanbanLoad = .idle
    public private(set) var boardsCode: String?
    public private(set) var boardLoads: [String: KanbanLoad] = [:]
    public private(set) var cardLoads: [String: KanbanLoad] = [:]
    public private(set) var settledGenerations: [String: Int] = [:]

    @ObservationIgnored private let service: KanbanService
    @ObservationIgnored private let disk: KanbanDiskCache?
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var restored: Set<String> = []

    public init(service: KanbanService, disk: KanbanDiskCache? = nil, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.service = service
        self.disk = disk
        self.sleep = sleep
    }

    public func boardName(_ board: String) -> String? {
        KanbanReadiness.boardName(session: session, board: board)
    }

    public func restore(board: String) async {
        guard let disk, session.cache(board) == nil, restored.insert(board).inserted else { return }
        guard let saved = await disk.load(board: board), session.cache(board) == nil else { return }
        session.restore(saved, board: board)
        if let generation = session.cache(board)?.generation { settledGenerations[board] = generation }
    }

    public func lastBoard() async -> String? {
        await disk?.lastBoard()
    }

    public func remember(board: String) {
        disk?.saveLastBoard(board)
    }

    public func load(of board: String) -> KanbanLoad {
        boardLoads[board] ?? .idle
    }

    public func cardLoad(board: String, taskID: String) -> KanbanLoad {
        cardLoads["\(board)/\(taskID)"] ?? .idle
    }

    public func events(board: String, taskID: String) -> [KanbanEvent] {
        Array((session.cache(board)?.events ?? []).filter { $0.taskID == taskID }.reversed())
    }

    public func loadBoards() async {
        if boardsLoad != .ready { boardsLoad = .loading }
        for attempt in 0...1 {
            do {
                let list = try await service.boards(gatewayID: session.requestGatewayID)
                session.adopt(gatewayID: list.gatewayID)
                session.setBoards(list.boards)
                boardsCode = list.boards.isEmpty && !list.isVerifiedEmpty ? "boards_unverified" : nil
                boardsLoad = boardsCode == nil ? .ready : .failed
                return
            } catch KanbanFailure.gatewayMismatch where attempt == 0 {
                session.release()
            } catch is CancellationError {
                return
            } catch {
                boardsCode = String(describing: KanbanFailure.classify(error))
                boardsLoad = KanbanLoad.from(KanbanFailure.classify(error))
                return
            }
        }
    }

    public func refreshSnapshot(board: String) async {
        await restore(board: board)
        if session.cache(board) == nil { boardLoads[board] = .loading }
        var restarts = 0
        while restarts <= Self.maxSnapshotRestarts {
            switch await snapshotPass(board: board) {
            case .published:
                boardLoads[board] = .ready
                persist(board)
                return
            case .restart:
                restarts += 1
            case .stopped(let load):
                if !Task.isCancelled { boardLoads[board] = load }
                return
            }
        }
        boardLoads[board] = .failed
    }

    public func loadCard(board: String, taskID: String) async {
        await fetchCard(board: board, taskID: taskID)
        persist(board)
    }

    private func fetchCard(board: String, taskID: String, retryAfterDrop: Bool = true) async {
        let slot = "\(board)/\(taskID)"
        if session.detail(board: board, taskID: taskID) == nil { cardLoads[slot] = .loading }
        do {
            let result = try await service.card(board: board, taskID: taskID, gatewayID: session.requestGatewayID)
            if session.adopt(gatewayID: result.scope.gatewayID) {
                if retryAfterDrop { await fetchCard(board: board, taskID: taskID, retryAfterDrop: false) }
                return
            }
            switch result.state {
            case .present:
                session.store(result, board: board)
                cardLoads[slot] = .ready
            case .cardAbsent:
                session.removeCard(board: board, taskID: taskID)
                cardLoads[slot] = .cardAbsent
            case .boardAbsent:
                forget(board)
                boardLoads[board] = .boardAbsent
            case .boardArchived:
                forget(board)
                boardLoads[board] = .boardArchived
            default:
                cardLoads[slot] = .failed
            }
        } catch KanbanFailure.gatewayMismatch {
            session.release()
            if retryAfterDrop { await fetchCard(board: board, taskID: taskID, retryAfterDrop: false) }
        } catch is CancellationError {
            return
        } catch {
            cardLoads[slot] = KanbanLoad.from(KanbanFailure.classify(error))
        }
    }

    public func prefetchDetails(board: String) async {
        guard let generation = session.cache(board)?.generation else { return }
        let missing = (session.cache(board)?.sortedCards ?? []).filter { session.detail(board: board, taskID: $0.taskID) == nil }
        await withTaskGroup(of: Void.self) { group in
            for card in missing.prefix(Self.maxPrefetchedCards) {
                group.addTask { await self.fetchCard(board: board, taskID: card.taskID) }
            }
        }
        if Task.isCancelled { return }
        if session.cache(board)?.generation == generation { settledGenerations[board] = generation }
        if !missing.isEmpty { persist(board) }
    }

    public func pollOnce(board: String) async -> KanbanPollStep {
        await restore(board: board)
        guard let cache = session.cache(board), let cursor = cache.cursor else {
            return await snapshotStep(board: board)
        }
        do {
            let page = try await service.events(board: board, cursor: cursor, limit: Self.eventPageSize, gatewayID: session.requestGatewayID)
            if session.adopt(gatewayID: page.scope.gatewayID) {
                await refreshSnapshot(board: board)
                return .wait
            }
            return await handle(page, board: board, generation: cache.generation)
        } catch KanbanFailure.gatewayMismatch {
            session.release()
            return await snapshotStep(board: board)
        } catch is CancellationError {
            return .stop
        } catch {
            switch KanbanFailure.classify(error) {
            case .unsupported:
                boardLoads[board] = .unsupported
                return .stop
            case .permissionDenied, .profileMismatch:
                boardLoads[board] = .permissionDenied
                return .stop
            case .unreachable:
                if session.cache(board) != nil { boardLoads[board] = .unreachable }
                return .backoff
            default:
                return .backoff
            }
        }
    }

    private func snapshotStep(board: String) async -> KanbanPollStep {
        await refreshSnapshot(board: board)
        switch boardLoads[board] ?? .idle {
        case .unsupported, .permissionDenied: return .stop
        case .failed, .unreachable: return .backoff
        default: return .wait
        }
    }

    public func poll(board: String) async {
        var failures = 0
        while !Task.isCancelled {
            let delay: Duration
            switch await pollOnce(board: board) {
            case .again:
                failures = 0
                continue
            case .wait:
                failures = 0
                delay = KanbanPollSchedule.interval
            case .backoff:
                failures += 1
                delay = KanbanPollSchedule.delay(afterFailures: failures)
            case .stop:
                return
            }
            do { try await sleep(delay) } catch { return }
        }
    }

    private enum Pass {
        case published
        case restart
        case stopped(KanbanLoad)
    }

    private func snapshotPass(board: String) async -> Pass {
        var staging = KanbanSnapshotStaging()
        var token: String?
        do {
            while true {
                let page = try await service.snapshot(board: board, gatewayID: session.requestGatewayID, limit: Self.pageSize, pageToken: token)
                if session.adopt(gatewayID: page.scope.gatewayID) { return .restart }
                switch staging.absorb(page, board: board) {
                case .more(let next):
                    token = next
                case .complete(let cursor):
                    session.publish(staging, cursor: cursor, board: board)
                    return .published
                case .restart:
                    return .restart
                case .unavailable(let state):
                    return stopped(for: state, board: board)
                }
            }
        } catch KanbanFailure.gatewayMismatch {
            session.release()
            return .restart
        } catch is CancellationError {
            return .stopped(boardLoads[board] ?? .idle)
        } catch {
            return .stopped(KanbanLoad.from(KanbanFailure.classify(error)))
        }
    }

    private func stopped(for state: KanbanReadState, board: String) -> Pass {
        switch state {
        case .boardAbsent:
            forget(board)
            return .stopped(.boardAbsent)
        case .boardArchived:
            forget(board)
            return .stopped(.boardArchived)
        default:
            return .stopped(.failed)
        }
    }

    private func handle(_ page: KanbanEventsPage, board: String, generation: Int) async -> KanbanPollStep {
        switch page.state {
        case .ok:
            if boardLoads[board] == .unreachable { boardLoads[board] = .ready }
            let applied = session.apply(page, board: board, generation: generation)
            await refreshCards(applied.affectedTaskIDs, board: board)
            return page.hasMore && !applied.affectedTaskIDs.isEmpty ? .again : .wait
        case .snapshotRequired, .cardAbsent:
            await refreshSnapshot(board: board)
            return .wait
        case .boardAbsent:
            forget(board)
            boardLoads[board] = .boardAbsent
            return .wait
        case .boardArchived:
            forget(board)
            boardLoads[board] = .boardArchived
            return .wait
        case .present, .unknown:
            return .backoff
        }
    }

    private func refreshCards(_ taskIDs: [String], board: String) async {
        guard !taskIDs.isEmpty else { return }
        if taskIDs.count > Self.maxCardRefreshes {
            await refreshSnapshot(board: board)
            return
        }
        for taskID in taskIDs { await fetchCard(board: board, taskID: taskID) }
        persist(board)
    }

    private func persist(_ board: String) {
        disk?.save(session, board: board)
    }

    private func forget(_ board: String) {
        session.removeBoard(board)
        settledGenerations[board] = nil
        disk?.remove(board: board)
    }
}
