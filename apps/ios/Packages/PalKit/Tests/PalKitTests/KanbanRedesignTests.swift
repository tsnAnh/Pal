import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban columns and titles")
struct KanbanRedesignTests {
    private static let gatewayStatuses = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done", "archived"]

    private func row(_ id: String, wire: String, title: String = "", body: String? = nil) throws -> KanbanCardRow {
        let card = KanbanCard(cardID: "g/b/\(id)", taskID: id, title: title, status: KanbanCardStatus(wire: wire))
        guard let body else { return KanbanCardRow(card: card, project: nil) }
        let json: JSONValue = [
            "state": "present", "scope": KanbanJSON.scope("g"),
            "detail": ["card": KanbanJSON.card(id, status: wire), "body": .string(body), "evidence": .array([]), "cursor": "c"],
        ]
        return KanbanCardRow(card: card, project: nil, detail: try #require(KanbanCardResult(json)?.detail))
    }

    @Test("hyphen, underscore and case variants of a state decode to the same status")
    func variants() {
        let expected: [(String, KanbanCardStatus)] = [
            ("in-progress", .running), ("in_progress", .running), ("In Progress", .running), ("inprogress", .running),
            ("in-review", .review), ("in_review", .review), ("Review", .review),
            ("completed", .done), ("DONE", .done), ("To-Do", .todo), ("to_do", .todo),
        ]
        for (wire, status) in expected { #expect(KanbanCardStatus(wire: wire) == status, "\(wire) decodes to its status") }
        #expect(KanbanCardStatus(wire: "teleported") == .unknown("teleported"), "an unknown state is kept raw")
    }

    @Test("each state lands in exactly one column and column counts equal the cards they show")
    func countsEqualCards() throws {
        let wires = Self.gatewayStatuses + ["in-progress", "in_review", "weird", ""]
        let rows = try wires.enumerated().map { try row("t\($0.offset)", wire: $0.element) }
        let layout = KanbanBoardLayout(rows: rows, filter: KanbanFilter())
        let shown = layout.columns.flatMap(\.rows).map(\.card.taskID)
        #expect(shown.count == rows.count, "every card is shown")
        #expect(Set(shown).count == shown.count, "no card appears in two columns")
        for column in layout.columns {
            #expect(column.rows.allSatisfy { $0.column == column.column }, "a column only holds its own cards")
            #expect(column.total == column.rows.count, "the count equals the shown cards")
        }
    }

    @Test("done is always present and a hidden column never swallows a card")
    func doneAndHidden() throws {
        let none = KanbanBoardLayout(rows: [], filter: KanbanFilter())
        #expect(none.columns.contains { $0.column == .done }, "done shows on an empty board")
        let blocked = KanbanBoardLayout(rows: [try row("a", wire: "blocked")], filter: KanbanFilter())
        #expect(blocked.columns.first { $0.column == .blocked }?.rows.count == 1, "a blocked card makes its column appear")
        let filtered = KanbanBoardLayout(rows: [try row("a", wire: "ready"), try row("b", wire: "ready", title: "x")], filter: KanbanFilter(text: "zzz"))
        #expect(filtered.columns.contains { $0.column == .done }, "done stays while a filter matches nothing")
    }

    @Test("a row shows its card title, or its task id when the title is blank")
    func rowTitle() throws {
        #expect(try row("t1", wire: "ready", title: "raw-key", body: "Key: a\n# Real title").displayTitle == "raw-key", "the card title wins over the body")
        #expect(try row("t2", wire: "ready").displayTitle == "t2", "an empty title shows the task id")
        let blank = try row("t3", wire: "ready", title: "  \n", body: "/faker-mode\n# Real heading")
        #expect(blank.displayTitle == "t3", "a whitespace title shows the task id, never a body line")
    }

    @Test("a card titled setup-slack with a slash-command body shows setup-slack on the tile, the detail and in search")
    func titleSurvivesSlashBody() throws {
        let setup = try row("t_1", wire: "ready", title: "setup-slack", body: "/faker-mode\nUnit: setup-slack")
        #expect(setup.displayTitle == "setup-slack", "the tile and the detail both render displayTitle")
        #expect(KanbanFilter(text: "setup-slack").matches(setup), "search finds the card by its title")
        let plain = try row("t_2", wire: "ready", title: "Fix login", body: "Key: PAL-2\n# Fix login\nmore")
        #expect(plain.displayTitle == "Fix login", "a normal card is unchanged")
    }
}
