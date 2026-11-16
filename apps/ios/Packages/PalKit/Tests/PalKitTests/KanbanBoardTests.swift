import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban board model")
struct KanbanBoardTests {
    private func card(_ id: String, _ status: KanbanCardStatus, title: String? = nil, bot: String? = nil, priority: Int? = nil, created: Int? = 1, completed: Int? = nil) -> KanbanCard {
        KanbanCard(cardID: "g/b/\(id)", taskID: id, title: title ?? id, status: status, assignee: bot, priority: priority, createdAt: created, completedAt: completed)
    }

    private func detail(_ id: String, status: String = "ready", body: String?, evidence: [JSONValue] = []) throws -> KanbanCardDetail {
        let json: JSONValue = [
            "state": "present", "scope": KanbanJSON.scope("gw"),
            "detail": ["card": KanbanJSON.card(id, status: status), "body": body.map(JSONValue.string) ?? .null, "evidence": .array(evidence), "cursor": "c"],
        ]
        return try #require(KanbanCardResult(json)?.detail)
    }

    private func row(_ id: String, _ status: KanbanCardStatus, title: String? = nil, bot: String? = nil, project: String? = nil, detail: KanbanCardDetail? = nil) -> KanbanCardRow {
        KanbanCardRow(card: card(id, status, title: title, bot: bot), project: project, detail: detail)
    }

    @Test("every gateway state lands in a column and an unknown state lands in the backlog")
    func stateToColumn() {
        let expected: [(KanbanCardStatus, KanbanColumn)] = [
            (.triage, .backlog), (.todo, .backlog), (.scheduled, .backlog), (.ready, .ready), (.running, .inProgress),
            (.blocked, .blocked), (.review, .review), (.done, .done), (.archived, .done), (.unknown("teleported"), .backlog), (.unknown(""), .backlog),
        ]
        for (status, column) in expected { #expect(KanbanColumn(status: status) == column, "\(status.wire)") }
        for wire in ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done", "archived"] {
            if case .unknown = KanbanCardStatus(wire: wire) { Issue.record("\(wire) decodes as unknown") }
        }
    }

    @Test("columns keep the core four, show blocked and review only when used, and sort within a column")
    func layout() {
        let rows = [
            row("a", .ready), row("b", .blocked), row("c", .done), row("d", .archived), row("e", .unknown("weird")),
        ]
        let layout = KanbanBoardLayout(rows: rows, filter: KanbanFilter())
        #expect(layout.columns.map(\.column) == [.backlog, .ready, .inProgress, .blocked, .done])
        #expect(layout.columns.first { $0.column == .backlog }?.rows.map(\.card.taskID) == ["e"])
        #expect(layout.columns.first { $0.column == .done }?.rows.count == 2)
        let empty = KanbanBoardLayout(rows: [row("a", .ready)], filter: KanbanFilter())
        #expect(empty.columns.map(\.column) == [.backlog, .ready, .inProgress, .done])
    }

    @Test("done cards list the newest completion first, others by priority then age")
    func ordering() {
        let done = [
            KanbanCardRow(card: card("old", .done, completed: 10), project: nil), KanbanCardRow(card: card("new", .done, completed: 20), project: nil),
        ]
        let ready = [
            KanbanCardRow(card: card("low", .ready, priority: 0, created: 1), project: nil),
            KanbanCardRow(card: card("high", .ready, priority: 5, created: 9), project: nil),
            KanbanCardRow(card: card("older", .ready, priority: 0, created: 0), project: nil),
        ]
        let layout = KanbanBoardLayout(rows: done + ready, filter: KanbanFilter())
        #expect(layout.columns.first { $0.column == .done }?.rows.map(\.card.taskID) == ["new", "old"])
        #expect(layout.columns.first { $0.column == .ready }?.rows.map(\.card.taskID) == ["high", "older", "low"])
    }

    @Test("filters combine: bot, project, state and text over title and body; counts keep the unfiltered totals")
    func filtering() throws {
        let withBody = try detail("t2", body: "Rotate the **staging** keys")
        let rows = [
            row("t1", .ready, title: "Ship the Café menu", bot: "alpha", project: "pal"),
            row("t2", .ready, title: "Rotate keys", bot: "beta", project: "pal", detail: withBody),
            row("t3", .done, title: "Old thing", bot: "alpha", project: "web"),
        ]
        func ids(_ filter: KanbanFilter) -> [String] {
            KanbanBoardLayout(rows: rows, filter: filter).columns.flatMap(\.rows).map(\.card.taskID).sorted()
        }
        #expect(ids(KanbanFilter()) == ["t1", "t2", "t3"])
        #expect(ids(KanbanFilter(bot: "alpha")) == ["t1", "t3"])
        #expect(ids(KanbanFilter(project: "web")) == ["t3"])
        #expect(ids(KanbanFilter(column: .ready)) == ["t1", "t2"])
        #expect(ids(KanbanFilter(text: "cafe")) == ["t1"])
        #expect(ids(KanbanFilter(text: "STAGING")) == ["t2"])
        #expect(ids(KanbanFilter(text: "keys staging")) == ["t2"])
        #expect(ids(KanbanFilter(text: "keys menu")) == [])
        #expect(ids(KanbanFilter(text: "  ")) == ["t1", "t2", "t3"])
        #expect(ids(KanbanFilter(bot: "alpha", column: .done)) == ["t3"])
        let layout = KanbanBoardLayout(rows: rows, filter: KanbanFilter(bot: "beta"))
        #expect(layout.columns.first { $0.column == .ready }?.total == 2)
        #expect(layout.matchingCards == 1 && layout.totalCards == 3)
        #expect(layout.projects == ["pal", "web"] && layout.bots == ["alpha", "beta"])
        #expect(!KanbanFilter(text: " ").isActive && KanbanFilter(bot: "x").isActive)
    }

    @MainActor
    @Test("rows pick up cached details and the board's project, and a live update keeps the filter's result consistent")
    func rowsFromSession() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot([KanbanJSON.card("t1", status: "ready")], cursor: "c0"))
        script.enqueue("kanban.card.get", KanbanJSON.cardResult("t1", status: "done"))
        script.enqueue("kanban.events.since", KanbanJSON.events([KanbanJSON.event(1, task: "t1", kind: "completed")], cursor: "c1"))
        let store = KanbanStore(service: KanbanService(gateway: script.gateway), sleep: { _ in })
        let filter = KanbanFilter(column: .done)
        _ = await store.pollOnce(board: "ops")
        let before = KanbanBoardLayout(rows: KanbanBoardLayout.rows(session: store.session, board: "ops"), filter: filter)
        #expect(before.matchingCards == 0)
        _ = await store.pollOnce(board: "ops")
        let after = KanbanBoardLayout(rows: KanbanBoardLayout.rows(session: store.session, board: "ops"), filter: filter)
        #expect(after.columns.first { $0.column == .done }?.rows.map(\.card.taskID) == ["t1"])
    }

    @Test("age reads as a short label and never goes negative")
    func age() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func label(_ ago: Int) -> String? { KanbanPresentation.age(since: 1_000_000 - ago, now: now) }
        #expect(label(5) == "now")
        #expect(label(59) == "now")
        #expect(label(60) == "1m")
        #expect(label(3_599) == "59m")
        #expect(label(3_600) == "1h")
        #expect(label(86_399) == "23h")
        #expect(label(86_400) == "1d")
        #expect(label(13 * 86_400) == "13d")
        #expect(label(14 * 86_400) == "2w")
        #expect(label(59 * 86_400) == "8w")
        #expect(label(60 * 86_400) == "2mo")
        #expect(label(364 * 86_400) == "12mo")
        #expect(label(365 * 86_400) == "1y")
        #expect(label(-500) == "now")
        #expect(KanbanPresentation.age(since: nil, now: now) == nil)
        #expect(KanbanPresentation.age(since: 0, now: now) == nil)
    }

    @Test("pull requests come from evidence with web links only")
    func pullRequests() throws {
        func evidence(_ id: Int, _ kind: String, _ url: String) -> JSONValue {
            ["evidence_id": .int(id), "kind": .string(kind), "payload": ["pr_url": .string(url)], "producer_profile": "bot", "source": "github"]
        }
        let item = try detail("t1", body: nil, evidence: [
            evidence(1, "pr_published", "https://github.com/o/r/pull/1"), evidence(2, "pr_merged", "javascript:alert(1)"),
            ["evidence_id": 3, "kind": "execution_ref", "payload": [:], "producer_profile": "bot", "source": "attestation"],
        ])
        let row = KanbanCardRow(card: item.card, project: nil, detail: item)
        #expect(row.evidenceCount == 3)
        #expect(row.pullRequests.map(\.evidenceID) == [1, 2])
        #expect(row.pullRequests.map(\.url?.absoluteString) == ["https://github.com/o/r/pull/1", nil])
        #expect(row.hasMergedPullRequest)
    }
}
