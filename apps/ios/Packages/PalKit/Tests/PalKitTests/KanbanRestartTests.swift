import PalKanban
import Testing

@MainActor
@Suite("Kanban across a gateway restart")
struct KanbanRestartTests {
    @Test("a restart with an offline window keeps the shown cards, reloads under the new gateway id and resumes events")
    func restartMidSession() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.boards.list", KanbanJSON.boards(gateway: "A"))
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", gateway: "A")], cursor: "cA", gateway: "A"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1", gateway: "A"))
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
        await store.loadBoards()
        await store.refreshSnapshot(board: "ops")
        await store.prefetchDetails(board: "ops")
        let shown = try #require(store.visibleRows(board: "ops"))
        #expect(shown.map(\.card.taskID) == ["t1"])

        script.enqueue("kanban.events.since", .unreachable)
        #expect(await store.pollOnce(board: "ops") == .backoff)
        #expect(store.visibleRows(board: "ops") == shown, "cards stay while the gateway is down")
        #expect(store.load(of: "ops") == .unreachable)

        script.enqueue("kanban.events.since", KanbanJSON.refusal("gateway_mismatch"))
        script.enqueue("kanban.board.snapshot", .unreachable)
        #expect(await store.pollOnce(board: "ops") == .backoff, "a reload that cannot reach the gateway backs off")
        #expect(store.visibleRows(board: "ops") == shown, "cards stay while the reload is pending")
        #expect(store.session.boards.map(\.scope.board) == ["ops"], "the board list is not emptied")

        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot(
            [KanbanJSON.card("t1", gateway: "B"), KanbanJSON.card("t2", gateway: "B")], cursor: "cB", gateway: "B"))
        #expect(await store.pollOnce(board: "ops") == .wait)
        #expect(store.session.gatewayID == "B")
        #expect(store.load(of: "ops") == .ready)
        #expect(store.visibleRows(board: "ops")?.map(\.card.taskID).contains("t1") == true, "no empty board after the reload")
        #expect(script.calls("kanban.board.snapshot").dropFirst().allSatisfy { $0.params["gateway_id"]?.stringValue != "A" })

        script.enqueue("kanban.events.since", KanbanJSON.events([], cursor: "cB2", gateway: "B"))
        #expect(await store.pollOnce(board: "ops") == .wait)
        let resumed = try #require(script.calls("kanban.events.since").last)
        #expect(resumed.params["gateway_id"]?.stringValue == "B")
        #expect(resumed.params["cursor"]?.stringValue == "cB")
    }

    @Test("the boards list reloads under the new gateway id without emptying the list")
    func boardsAfterRestart() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.boards.list", KanbanJSON.boards(gateway: "A", slugs: ["ops", "lab"]))
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
        await store.loadBoards()
        script.enqueue("kanban.boards.list", KanbanJSON.refusal("gateway_mismatch"))
        script.enqueue("kanban.boards.list", KanbanJSON.boards(gateway: "B", slugs: ["ops", "lab"]))
        await store.loadBoards()
        #expect(store.boardsLoad == .ready)
        #expect(store.session.gatewayID == "B")
        #expect(store.session.boards.map(\.scope.board) == ["ops", "lab"])
        #expect(script.calls("kanban.boards.list").last?.params.keys.contains("gateway_id") == false)
    }
}
