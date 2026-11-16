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
    public private(set) var boardLoads: [String: KanbanLoad] = [:]
    public private(set) var cardLoads: [String: KanbanLoad] = [:]

    @ObservationIgnored private let service: KanbanService
    @ObservationIgnored private let sleep: Sleep

    public init(service: KanbanService, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.service = service
        self.sleep = sleep
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
                let list = try await service.boards(gatewayID: session.gatewayID)
                absorb(gatewayID: list.gatewayID)
                session.setBoards(list.boards)
                boardsLoad = .ready
                return
            } catch KanbanFailure.gatewayMismatch where attempt == 0 {
                drop()
            } catch is CancellationError {
                return
            } catch {
                boardsLoad = KanbanLoad.from(KanbanFailure.classify(error))
                return
            }
        }
    }

    public func refreshSnapshot(board: String) async {
        if session.cache(board) == nil { boardLoads[board] = .loading }
        var restarts = 0
        while restarts <= Self.maxSnapshotRestarts {
            switch await snapshotPass(board: board) {
            case .published:
                boardLoads[board] = .ready
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

    public func loadCard(board: String, taskID: String, retryAfterDrop: Bool = true) async {
        let slot = "\(board)/\(taskID)"
        if session.detail(board: board, taskID: taskID) == nil { cardLoads[slot] = .loading }
        do {
            let result = try await service.card(board: board, taskID: taskID, gatewayID: session.gatewayID)
            if absorb(gatewayID: result.scope.gatewayID) {
                if retryAfterDrop { await loadCard(board: board, taskID: taskID, retryAfterDrop: false) }
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
                session.removeBoard(board)
                boardLoads[board] = .boardAbsent
            case .boardArchived:
                session.removeBoard(board)
                boardLoads[board] = .boardArchived
            default:
                cardLoads[slot] = .failed
            }
        } catch KanbanFailure.gatewayMismatch {
            drop()
            if retryAfterDrop { await loadCard(board: board, taskID: taskID, retryAfterDrop: false) }
        } catch is CancellationError {
            return
        } catch {
            cardLoads[slot] = KanbanLoad.from(KanbanFailure.classify(error))
        }
    }

    public func prefetchDetails(board: String) async {
        let missing = (session.cache(board)?.sortedCards ?? []).filter { session.detail(board: board, taskID: $0.taskID) == nil }
        for card in missing.prefix(Self.maxPrefetchedCards) {
            if Task.isCancelled { return }
            await loadCard(board: board, taskID: card.taskID)
        }
    }

    public func pollOnce(board: String) async -> KanbanPollStep {
        guard let cache = session.cache(board), let cursor = cache.cursor else {
            await refreshSnapshot(board: board)
            switch boardLoads[board] ?? .idle {
            case .unsupported, .permissionDenied: return .stop
            case .failed, .unreachable: return .backoff
            default: return .wait
            }
        }
        do {
            let page = try await service.events(board: board, cursor: cursor, limit: Self.eventPageSize, gatewayID: session.gatewayID)
            if absorb(gatewayID: page.scope.gatewayID) {
                await refreshSnapshot(board: board)
                return .wait
            }
            return await handle(page, board: board, generation: cache.generation)
        } catch KanbanFailure.gatewayMismatch {
            drop()
            await refreshSnapshot(board: board)
            return .wait
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
                let page = try await service.snapshot(board: board, gatewayID: session.gatewayID, limit: Self.pageSize, pageToken: token)
                if absorb(gatewayID: page.scope.gatewayID) { return .restart }
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
            drop()
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
            session.removeBoard(board)
            return .stopped(.boardAbsent)
        case .boardArchived:
            session.removeBoard(board)
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
            session.removeBoard(board)
            boardLoads[board] = .boardAbsent
            return .wait
        case .boardArchived:
            session.removeBoard(board)
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
        for taskID in taskIDs { await loadCard(board: board, taskID: taskID) }
    }

    @discardableResult
    private func absorb(gatewayID: String) -> Bool {
        let dropped = session.adopt(gatewayID: gatewayID)
        if dropped { clearLoads() }
        return dropped
    }

    private func drop() {
        session.dropAll()
        clearLoads()
    }

    private func clearLoads() {
        boardLoads = [:]
        cardLoads = [:]
    }
}
