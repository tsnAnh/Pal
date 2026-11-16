import Foundation
import PalKanban
import Testing

@MainActor
@Suite("Kanban live follow")
struct KanbanFollowTests {
    private func cursors(_ script: KanbanScript) -> [String?] {
        script.calls("kanban.events.since").map { $0.params["cursor"]?.stringValue }
    }

    @Test("the loop re-reads the log every interval, applies events in order and drops duplicates")
    func followsEveryInterval() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1")], cursor: "c1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(2, task: "t1"), KanbanJSON.event(1, task: "t1")], cursor: "c2"))
        let delays = DelayLog()
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { delay in
            if delays.record(delay) == 4 { throw CancellationError() }
        })
        await store.poll(board: "ops")
        #expect(delays.all == Array(repeating: .seconds(2), count: 4))
        #expect(cursors(script) == ["c0", "c1", "c2"])
        #expect(store.session.cache("ops")?.events.map(\.eventID) == [1, 2])
        #expect(script.calls("kanban.board.snapshot").count == 1)
    }

    @Test("after a network loss the next read resumes from the stored cursor and the board reads as reconnecting meanwhile")
    func resumesFromStoredCursor() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(await store.pollOnce(board: "ops") == .backoff)
        #expect(store.load(of: "ops") == .unreachable)
        #expect(store.session.cache("ops")?.cursor == "c0")
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1")], cursor: "c1"))
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(cursors(script) == ["c0", "c0"])
        #expect(store.load(of: "ops") == .ready)
        #expect(script.calls("kanban.board.snapshot").count == 1)
    }

    @Test("snapshot_required and card_absent each cost exactly one fresh snapshot, then the follow continues from its cursor")
    func snapshotRequiredThenContinue() async throws {
        for state in ["snapshot_required", "card_absent"] {
            let script = KanbanScript()
            script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
            script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: nil, state: state, reason: "history_changed"))
            let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
            #expect(await store.pollOnce(board: "ops") == .wait)
            script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1"), KanbanJSON.card("t2")], cursor: "c9"))
            #expect(await store.pollOnce(board: "ops") == .wait)
            #expect(script.calls("kanban.board.snapshot").count == 2, state)
            script.enqueue("kanban.card.get", KanbanJSON.cardResult("t2"))
            script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t2")], cursor: "c10"))
            #expect(await store.pollOnce(board: "ops") == .wait)
            #expect(cursors(script) == ["c0", "c9"], state)
            #expect(script.calls("kanban.board.snapshot").count == 2, state)
            #expect(store.session.cache("ops")?.cursor == "c10")
        }
    }

    @Test("a hidden board is not followed, and a board shown again resumes from its stored cursor without a new snapshot")
    func pauseAndResume() async throws {
        #expect(KanbanFollowTarget(board: "ops", isActive: true).followedBoard == "ops")
        #expect(KanbanFollowTarget(board: "ops", isActive: false).followedBoard == nil)
        #expect(KanbanFollowTarget(board: nil, isActive: true).followedBoard == nil)

        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1")], cursor: "c1"))
        let delays = DelayLog()
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { delay in
            if [1, 3].contains(delays.record(delay)) { throw CancellationError() }
        })
        await store.poll(board: "ops")
        #expect(script.calls("kanban.events.since").isEmpty)
        await store.poll(board: "ops")
        #expect(cursors(script).first == "c0")
        #expect(script.calls("kanban.board.snapshot").count == 1)
        #expect(delays.all.count == 3)
    }
}
