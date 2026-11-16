import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Synchronization
import Testing

final class KanbanScript: Sendable {
    struct Call: Sendable {
        let method: String
        let params: [String: JSONValue]
    }

    enum Reply: Sendable {
        case result(JSONValue)
        case failure(RPCError)
    }

    private let queues = Mutex<[String: [Reply]]>([:])
    private let served = Mutex<[String: Reply]>([:])
    private let log = Mutex<[Call]>([])

    func enqueue(_ method: String, _ reply: Reply) {
        queues.withLock { $0[method, default: []].append(reply) }
    }

    func enqueue(_ method: String, _ result: JSONValue) {
        enqueue(method, .result(result))
    }

    func calls(_ method: String) -> [Call] {
        log.withLock { $0.filter { $0.method == method } }
    }

    var allMethods: [String] { log.withLock { $0.map(\.method) } }

    var gateway: KanbanGateway {
        KanbanGateway { [self] method, params in
            log.withLock { $0.append(Call(method: method, params: params?.objectValue ?? [:])) }
            let next: Reply? = queues.withLock { table in
                guard var queue = table[method], !queue.isEmpty else { return nil }
                let first = queue.removeFirst()
                table[method] = queue
                return first
            }
            let reply = served.withLock { last -> Reply? in
                if let next { last[method] = next }
                return last[method]
            }
            switch reply {
            case .result(let value)?: return value
            case .failure(let error)?: throw GatewayTransportError.rpc(error)
            case nil: throw GatewayTransportError.timedOut
            }
        }
    }
}

final class DelayLog: Sendable {
    private let list = Mutex<[Duration]>([])

    var all: [Duration] { list.withLock { $0 } }

    func record(_ delay: Duration) -> Int {
        list.withLock { list in
            list.append(delay)
            return list.count
        }
    }
}

enum KanbanJSON {
    static func scope(_ gateway: String, _ board: String = "ops") -> JSONValue {
        ["gateway_id": .string(gateway), "board": .string(board), "board_id": .string("\(gateway)/\(board)")]
    }

    static func card(_ task: String, status: String = "ready", gateway: String = "gw", board: String = "ops", title: String? = nil) -> JSONValue {
        [
            "card_id": .string("\(gateway)/\(board)/\(task)"), "task_id": .string(task), "title": .string(title ?? task),
            "status": .string(status), "governed": false,
        ]
    }

    static func snapshot(
        _ cards: [JSONValue], next: String? = nil, cursor: String? = nil, edges: [(String, String)] = [],
        gateway: String = "gw", board: String = "ops", state: String = "present", reason: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "state": .string(state), "scope": scope(gateway, board), "cards": .array(cards),
            "prerequisites": .array(edges.map { ["task_id": .string($0.0), "requires_task_id": .string($0.1)] }),
        ]
        if let next { object["next_page_token"] = .string(next) }
        if let cursor { object["cursor"] = .string(cursor) }
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    static func event(_ id: Int, task: String, kind: String = "claimed", gateway: String = "gw") -> JSONValue {
        [
            "event_id": .int(id), "card_id": .string("\(gateway)/ops/\(task)"), "task_id": .string(task),
            "kind": .string(kind), "created_at": .int(100 + id), "data": [:],
        ]
    }

    static func events(
        _ events: [JSONValue], cursor: String?, hasMore: Bool = false, state: String = "ok", reason: String? = nil,
        gateway: String = "gw", board: String = "ops"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "state": .string(state), "scope": scope(gateway, board), "events": .array(events), "has_more": .bool(hasMore),
        ]
        if let cursor { object["cursor"] = .string(cursor) }
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    static func cardResult(_ task: String, status: String = "running", gateway: String = "gw", board: String = "ops") -> JSONValue {
        [
            "state": "present", "scope": scope(gateway, board),
            "detail": ["card": card(task, status: status, gateway: gateway, board: board), "cursor": "c"],
        ]
    }

    static func boards(gateway: String, slugs: [String] = ["ops"]) -> JSONValue {
        [
            "gateway_id": .string(gateway),
            "boards": .array(slugs.map { slug in
                ["scope": scope(gateway, slug), "name": .string(slug), "archived": false, "dispatch_mode": "workers", "task_counts": [:]]
            }),
        ]
    }

    static func refusal(_ reason: String, code: Int = 4001) -> KanbanScript.Reply {
        .failure(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }
}

@MainActor
@Suite("Kanban store")
struct KanbanStoreTests {
    private func makeStore(_ script: KanbanScript) -> KanbanStore {
        KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
    }

    @Test("pages are followed with the same limit until the token ends, then published with the final cursor")
    func pagingAcrossPages() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1"), KanbanJSON.card("t2")], next: "p2"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t3")], next: "p3", edges: [("t3", "t1")]))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t4")], cursor: "c-final", edges: [("t3", "t1")]))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        let calls = script.calls("kanban.board.snapshot")
        #expect(calls.map { $0.params["page_token"]?.stringValue } == [nil, "p2", "p3"])
        #expect(Set(calls.compactMap { $0.params["limit"]?.intValue }) == [KanbanStore.pageSize])
        let cache = try #require(store.session.cache("ops"))
        #expect(cache.cards.values.map(\.taskID).sorted() == ["t1", "t2", "t3", "t4"])
        #expect(cache.prerequisites == [KanbanPrerequisite(taskID: "t3", requiresTaskID: "t1")])
        #expect(cache.cursor == "c-final")
        #expect(store.load(of: "ops") == .ready)
    }

    @Test("a duplicate card across pages is one card")
    func dedupe() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", title: "old")], next: "p2"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", title: "new")], cursor: "c"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        #expect(store.session.cache("ops")?.cards.count == 1)
    }

    @Test("snapshot_required mid-paging discards the staged pages and restarts from page one")
    func restartMidPaging() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("stale")], next: "p2"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([], state: "snapshot_required", reason: "changed_during_snapshot"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("fresh")], cursor: "c2"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        let calls = script.calls("kanban.board.snapshot")
        #expect(calls.map { $0.params["page_token"]?.stringValue } == [nil, "p2", nil])
        #expect(store.session.cache("ops")?.cards.values.map(\.taskID) == ["fresh"])
        #expect(store.session.cache("ops")?.cursor == "c2")
    }

    @Test("every snapshot_required reason restarts, and restarts are bounded")
    func restartsAreBounded() async {
        for reason in ["wrong_gateway", "wrong_board", "stale_generation", "invalid_cursor", "changed_during_snapshot"] {
            let script = KanbanScript()
            script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([], state: "snapshot_required", reason: reason))
            let store = makeStore(script)
            await store.refreshSnapshot(board: "ops")
            #expect(script.calls("kanban.board.snapshot").count == KanbanStore.maxSnapshotRestarts + 1, "\(reason)")
            #expect(store.session.cache("ops") == nil)
            #expect(store.load(of: "ops") == .failed)
        }
    }

    @Test("a final page without a cursor is never adopted")
    func finalPageNeedsCursor() async {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")]))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        #expect(store.session.cache("ops") == nil)
    }

    @Test("a replayed snapshot_required refetches the whole snapshot")
    func replaySnapshotRequired() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c1"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1"), KanbanJSON.card("t9")], cursor: "c9"))
        script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: nil, state: "snapshot_required", reason: "history_changed"))
        let store = makeStore(script)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(script.calls("kanban.events.since").count == 1)
        #expect(script.calls("kanban.events.since").first?.params["cursor"]?.stringValue == "c1")
        #expect(store.session.cache("ops")?.cards.count == 2)
        #expect(store.session.cache("ops")?.cursor == "c9")
        #expect(store.session.cache("ops")?.highWater == 0)
    }

    @Test("a response from another gateway drops every cache and the old cursor is never sent again")
    func gatewayChangeDropsEverything() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "cursor-A", gateway: "A"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", gateway: "B")], cursor: "cursor-B", gateway: "B"))
        script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: "x", gateway: "B"))
        script.enqueue("kanban.boards.list", KanbanJSON.boards(gateway: "A", slugs: ["ops", "lab"]))
        let store = makeStore(script)
        await store.loadBoards()
        await store.refreshSnapshot(board: "ops")
        #expect(store.session.gatewayID == "A")
        #expect(store.session.cache("ops")?.cursor == "cursor-A")

        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(store.session.gatewayID == "B")
        #expect(store.session.cache("ops")?.cursor == "cursor-B")
        #expect(store.session.boards.isEmpty)
        #expect(store.session.caches.keys.allSatisfy { $0.gatewayID == "B" })
        #expect(script.calls("kanban.events.since").first?.params["cursor"]?.stringValue == "cursor-A")
        #expect(script.calls("kanban.events.since").count == 1)
        #expect(script.calls("kanban.board.snapshot").last?.params["gateway_id"]?.stringValue == "B")
    }

    @Test("a gateway_mismatch refusal drops all cached state and refetches without the old gateway id")
    func gatewayMismatchRefusal() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c1", gateway: "A"))
        script.enqueue("kanban.events.since", KanbanJSON.refusal("gateway_mismatch"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t2", gateway: "B")], cursor: "cB", gateway: "B"))
        #expect(await store.pollOnce(board: "ops") == .wait)
        let calls = script.calls("kanban.board.snapshot")
        #expect(calls.last?.params.keys.contains("gateway_id") == false)
        #expect(store.session.gatewayID == "B")
        #expect(store.session.cache("ops")?.cards.values.map(\.taskID) == ["t2"])
    }

    @Test("boards are separate scopes: cursors and cards never cross")
    func boardSwitch() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", board: "ops")], cursor: "ops-cursor", board: "ops"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", board: "lab"), KanbanJSON.card("t2", board: "lab")], cursor: "lab-cursor", board: "lab"))
        await store.refreshSnapshot(board: "lab")
        #expect(store.session.cache("ops")?.cursor == "ops-cursor")
        #expect(store.session.cache("lab")?.cursor == "lab-cursor")
        #expect(store.session.cache("ops")?.cards.count == 1)
        #expect(store.session.cache("lab")?.cards.count == 2)
        script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: "lab-cursor-2", board: "lab"))
        _ = await store.pollOnce(board: "lab")
        #expect(script.calls("kanban.events.since").last?.params["cursor"]?.stringValue == "lab-cursor")
        #expect(script.calls("kanban.events.since").last?.params["board"]?.stringValue == "lab")
        #expect(store.session.cache("ops")?.cursor == "ops-cursor")
    }

    @Test("a page answered for another board is not stitched in")
    func wrongBoardPage() async {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", board: "lab")], cursor: "c", board: "lab"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        #expect(store.session.cache("ops") == nil)
        #expect(store.session.cache("lab") == nil)
    }

    @Test("duplicate and reordered events apply once, in id order, and a stale batch changes nothing")
    func eventIdempotence() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1"), KanbanJSON.card("t2")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events(
            [KanbanJSON.event(5, task: "t1"), KanbanJSON.event(3, task: "t2"), KanbanJSON.event(4, task: "t1"), KanbanJSON.event(5, task: "t1")],
            cursor: "c5"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(4, task: "t1"), KanbanJSON.event(5, task: "t1")], cursor: "c-old"))
        let store = makeStore(script)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(await store.pollOnce(board: "ops") == .wait)
        let cache = try #require(store.session.cache("ops"))
        #expect(cache.events.map(\.eventID) == [3, 4, 5])
        #expect(cache.highWater == 5)
        #expect(cache.cursor == "c5")
        #expect(script.calls("kanban.events.since").last?.params["cursor"]?.stringValue == "c5")
    }

    @Test("unknown event kinds are kept in the list; events only re-read the affected cards")
    func eventsRefreshOnlyAffectedCards() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", status: "ready"), KanbanJSON.card("t2")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1", status: "done"))
        script.enqueue("kanban.events.since", KanbanJSON.events(
            [KanbanJSON.event(1, task: "t1", kind: "teleported"), KanbanJSON.event(2, task: "t1", kind: "completed")], cursor: "c2"))
        let store = makeStore(script)
        _ = await store.pollOnce(board: "ops")
        _ = await store.pollOnce(board: "ops")
        #expect(store.session.cache("ops")?.events.map(\.kind) == [.unknown("teleported"), .completed])
        #expect(script.calls("kanban.card.get").map { $0.params["task_id"]?.stringValue } == ["t1"])
        #expect(store.session.cache("ops")?.cards.values.first { $0.taskID == "t1" }?.status == .done)
        #expect(store.session.cache("ops")?.cards.values.first { $0.taskID == "t2" }?.status == .ready)
    }

    @Test("has_more continues immediately; the end of the log waits")
    func hasMoreContinues() async {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1")], cursor: "c1", hasMore: true))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(2, task: "t1")], cursor: "c2", hasMore: false))
        let store = makeStore(script)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(await store.pollOnce(board: "ops") == .again)
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(store.session.cache("ops")?.cursor == "c2")
    }

    @Test("a board that disappears or is archived shows a typed state and drops its cache")
    func absentAndArchived() async {
        for (state, expected) in [("board_absent", KanbanLoad.boardAbsent), ("board_archived", .boardArchived)] {
            let script = KanbanScript()
            script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
            script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: nil, state: state))
            let store = makeStore(script)
            await store.refreshSnapshot(board: "ops")
            _ = await store.pollOnce(board: "ops")
            #expect(store.load(of: "ops") == expected)
            #expect(store.session.cache("ops") == nil)
        }
    }

    @Test("card.get answers: card_absent removes the card, present updates cache and prerequisites")
    func cardReads() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1"), KanbanJSON.card("t2")], cursor: "c0"))
        let store = makeStore(script)
        await store.refreshSnapshot(board: "ops")
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1", status: "blocked"))
        await store.loadCard(board: "ops", taskID: "t1")
        #expect(store.session.detail(board: "ops", taskID: "t1")?.card.status == .blocked)
        script.enqueue("kanban.card.get", ["state": "card_absent", "scope": KanbanJSON.scope("gw")])
        await store.loadCard(board: "ops", taskID: "t2")
        #expect(store.cardLoad(board: "ops", taskID: "t2") == .cardAbsent)
        #expect(store.session.cache("ops")?.cards.values.map(\.taskID) == ["t1"])
    }

    @Test("a missing method stops polling and reads as not available on this server")
    func unsupported() async {
        let script = KanbanScript()
        script.enqueue("kanban.boards.list", .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"])))
        script.enqueue("kanban.board.snapshot", .failure(RPCError(code: -32601, message: "unknown_method")))
        let store = makeStore(script)
        await store.loadBoards()
        #expect(store.boardsLoad == .unsupported)
        #expect(await store.pollOnce(board: "ops") == .stop)
        #expect(store.load(of: "ops") == .unsupported)
        await store.poll(board: "ops")
        #expect(script.calls("kanban.board.snapshot").count == 2)
    }

    @Test("permission, profile and parameter refusals map to typed states")
    func refusals() async {
        let cases: [(String, KanbanLoad)] = [
            ("permission_denied", .permissionDenied), ("profile_mismatch", .permissionDenied), ("invalid_params", .failed),
        ]
        for (reason, expected) in cases {
            let script = KanbanScript()
            script.enqueue("kanban.boards.list", KanbanJSON.refusal(reason))
            let store = makeStore(script)
            await store.loadBoards()
            #expect(store.boardsLoad == expected, "\(reason)")
        }
    }

    @Test("network failures back off to a ceiling and a cancelled sleep ends the loop")
    func backoff() async {
        let delays = DelayLog()
        let script = KanbanScript()
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { delay in
            if delays.record(delay) == 8 { throw CancellationError() }
        })
        await store.poll(board: "ops")
        #expect(delays.all == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60), .seconds(60)])
        #expect(KanbanPollSchedule.delay(afterFailures: 0) == .seconds(5))
        #expect(KanbanPollSchedule.delay(afterFailures: 99) == .seconds(60))
    }

    @Test("a cancelled task stops polling without further requests")
    func cancellation() async {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: "c0"))
        let store = makeStore(script)
        let task = Task { await store.poll(board: "ops") }
        task.cancel()
        await task.value
        #expect(script.calls("kanban.events.since").count <= 1)
    }

    @Test("only the five read methods are ever called")
    func readOnlyCalls() async {
        let script = KanbanScript()
        script.enqueue("kanban.boards.list", KanbanJSON.boards(gateway: "gw"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1")], cursor: "c1"))
        let store = makeStore(script)
        await store.loadBoards()
        await store.refreshSnapshot(board: "ops")
        await store.loadCard(board: "ops", taskID: "t1")
        _ = await store.pollOnce(board: "ops")
        #expect(Set(script.allMethods).isSubset(of: Set(KanbanService.methods)))
    }
}
