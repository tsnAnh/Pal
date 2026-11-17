import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@MainActor
@Suite("Kanban boards list")
struct KanbanBoardsListTests {
    private func store(answering json: JSONValue) -> KanbanStore {
        let script = KanbanScript()
        script.enqueue("kanban.boards.list", json)
        return KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
    }

    private func row(_ slug: String, unavailable: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "scope": ["gateway_id": "gw", "board": .string(slug), "board_id": .string("gw/\(slug)")],
            "name": .string(slug), "archived": false, "dispatch_mode": "workers", "task_counts": .null,
        ]
        if let unavailable { object["unavailable"] = .string(unavailable) }
        return .object(object)
    }

    private func answer(_ rows: [JSONValue], seen: Int?) -> JSONValue {
        var object: [String: JSONValue] = ["gateway_id": "gw", "boards": .array(rows)]
        if let seen { object["boards_seen"] = .int(seen) }
        return .object(object)
    }

    @Test("a board the gateway could not open arrives as a row with its reason")
    func unavailableBoardIsARow() async {
        let store = store(answering: answer([row("default", unavailable: "absent")], seen: 1))
        await store.loadBoards()
        #expect(store.boardsLoad == .ready)
        #expect(store.session.boards.map(\.scope.board) == ["default"])
        #expect(store.session.boards.first?.unavailable == "absent")
    }

    @Test("an empty list the gateway counted as zero boards is the only one that reads as no boards yet")
    func verifiedEmptyIsReady() async {
        let store = store(answering: answer([], seen: 0))
        await store.loadBoards()
        #expect(store.boardsLoad == .ready)
        #expect(store.boardsCode == nil)
    }

    @Test("an empty list without a count, or with boards seen, is an error with a code")
    func unverifiedEmptyFails() async {
        for seen in [nil, 2] {
            let store = store(answering: answer([], seen: seen))
            await store.loadBoards()
            #expect(store.boardsLoad == .failed)
            #expect(store.boardsCode == "boards_unverified")
        }
    }

    @Test("one undecodable row fails the whole list instead of being dropped")
    func badRowFailsTheList() async {
        let bad: JSONValue = ["name": "no scope"]
        #expect(KanbanBoardsList(answer([row("default"), bad], seen: 2)) == nil)
        let store = store(answering: answer([row("default"), bad], seen: 2))
        await store.loadBoards()
        #expect(store.boardsLoad == .failed)
        #expect(store.boardsCode != nil)
    }

    @Test("an answer from a gateway that predates the reason still decodes")
    func oldAnswerDecodes() throws {
        let list = try #require(KanbanBoardsList(answer([row("default")], seen: nil)))
        #expect(list.boards.first?.unavailable == nil)
        #expect(list.boardsSeen == nil)
    }
}
