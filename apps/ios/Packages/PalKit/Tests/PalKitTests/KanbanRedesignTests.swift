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

    @Test("the title is the first readable body line")
    func titleFromBody() {
        let body = "\n\n  \nKey: PAL-1\nKind: part\n- Project: pal\n**Bot**: alpha\nOutcome: x\nState: ready\nAdded: 1\nUpdated: 2\nHistory: created\n## Ship the **beta** build\nmore text\n"
        #expect(KanbanBody.title(of: body, fallback: "t_1") == "Ship the beta build", "headings lose markers and machine lines are skipped")
        #expect(KanbanBody.title(of: "```\nKey: x\n", fallback: "t_1") == "t_1", "only machine lines and fences fall back")
        #expect(KanbanBody.title(of: nil, fallback: "t_1") == "t_1", "no body falls back")
        #expect(KanbanBody.title(of: "Key: PAL-1\nState: ready", fallback: "Card title") == "Card title", "a body of machine lines falls back")
        #expect(KanbanBody.title(of: "State of the art\n", fallback: "t") == "State of the art", "a line that only starts like a key is readable")
        #expect(KanbanBody.title(of: "/faker-mode\n# Real heading", fallback: "t") == "Real heading", "a leading slash command is skipped")
    }

    @Test("a row shows its card title, then the first readable body line, then its key")
    func rowTitle() throws {
        #expect(try row("t1", wire: "ready", title: "raw-key", body: "Key: a\n# Real title").displayTitle == "raw-key", "the card title wins over the body")
        #expect(try row("t2", wire: "ready", title: "Card title").displayTitle == "Card title", "no body uses the card title")
        #expect(try row("t3", wire: "ready").displayTitle == "t3", "an empty title falls back to the key")
        #expect(try row("t4", wire: "ready", title: "  ", body: "/faker-mode\n# Real heading").displayTitle == "Real heading", "a blank title skips a leading slash command")
        #expect(try row("t5", wire: "ready", title: "", body: "/faker-mode").displayTitle == "t5", "a body of only a slash command falls back to the key")
        #expect(try row("t6", wire: "ready", title: "", body: "  /faker-mode unit\n\nPlain words").displayTitle == "Plain words", "an indented slash command is skipped")
        #expect(try row("t7", wire: "ready", title: "", body: "/ not a command").displayTitle == "/ not a command", "a lone slash is readable text")
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
