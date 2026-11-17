import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban glass board presentation")
struct KanbanGlassBoardTests {
    private func row(evidence: [JSONValue], ci: String? = nil) throws -> KanbanCardRow {
        var detail: [String: JSONValue] = ["card": KanbanJSON.card("t1", status: "ready"), "evidence": .array(evidence), "cursor": "c"]
        if let ci { detail["ci_acceptance"] = ["state": .string(ci)] }
        let json: JSONValue = ["state": "present", "scope": KanbanJSON.scope("g"), "detail": .object(detail)]
        let parsed = try #require(KanbanCardResult(json)?.detail)
        return KanbanCardRow(card: parsed.card, project: nil, detail: parsed)
    }

    private func pr(_ id: Int, _ kind: String, number: Int) -> JSONValue {
        ["evidence_id": .int(id), "kind": .string(kind), "payload": ["pr_url": .string("https://github.com/acme/app/pull/\(number)")]]
    }

    @Test("a bot shows its display name, falls back to its handle, and an empty assignee shows nothing")
    func botName() {
        let bots = KanbanBots(displayNames: ["hermes-bot-mobile": "Mobile", "blank": "  "])
        #expect(bots.name(for: "hermes-bot-mobile") == "Mobile", "the display name wins over the handle")
        #expect(bots.name(for: "chief") == "chief", "an unknown bot falls back to its handle")
        #expect(bots.name(for: "blank") == "blank", "a blank display name falls back to the handle")
        #expect(bots.name(for: "") == nil, "an empty assignee has no name")
        #expect(bots.name(for: nil) == nil, "no assignee has no name")
    }

    @Test("filter options are sorted by the name the owner reads")
    func botOptionsByDisplayName() {
        let bots = KanbanBots(displayNames: ["zeta": "Alpha", "alpha": "Zulu"])
        #expect(bots.sorted(["alpha", "zeta"]) == ["zeta", "alpha"], "sorted by display name, not handle")
    }

    @Test("the PR chip state comes from the card's PR evidence and CI acceptance")
    func pullRequestState() throws {
        #expect(try row(evidence: []).pullRequest == nil, "no PR evidence shows no chip")
        let open = try #require(try row(evidence: [pr(1, "pr_published", number: 145)]).pullRequest)
        #expect(open == KanbanPullRequest(state: .open, number: 145), "a published PR is open")
        let merged = try #require(try row(evidence: [pr(1, "pr_published", number: 151), pr(2, "pr_merged", number: 151)], ci: "rejected").pullRequest)
        #expect(merged == KanbanPullRequest(state: .merged, number: 151), "merged wins over failing checks")
        let failing = try #require(try row(evidence: [pr(1, "pr_published", number: 146)], ci: "rejected").pullRequest)
        #expect(failing == KanbanPullRequest(state: .checksFailing, number: 146), "CI rejection of the PR head is checks failing")
        let accepted = try #require(try row(evidence: [pr(1, "pr_published", number: 147)], ci: "accepted").pullRequest)
        #expect(accepted.state == .open, "accepted checks stay open")
        let latest = try #require(try row(evidence: [pr(1, "pr_published", number: 10), pr(5, "pr_published", number: 12)]).pullRequest)
        #expect(latest.number == 12, "the newest PR evidence names the number")
    }

    @Test("the board is titled Pal Kanban")
    func title() {
        #expect(KanbanPresentation.surfaceTitle == "Pal Kanban", "the header, sheet and accessibility title")
    }
}
