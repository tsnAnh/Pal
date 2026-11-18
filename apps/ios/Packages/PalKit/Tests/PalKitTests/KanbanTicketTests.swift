import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban ticket parser")
struct KanbanTicketTests {
    private static let marker = "---- faker-kit machine fields (read by the kit, do not edit) ----"

    private func urls(_ strings: [String]) throws -> [URL] {
        try strings.map { try #require(URL(string: $0)) }
    }

    private func part(_ label: KanbanBodyLabel, in document: KanbanBodyDocument) -> KanbanBodyPart? {
        document.parts.first { $0.label == label }
    }

    @Test("the new ticket form yields the five labelled parts in fixed order, with the footer and ref set aside")
    func newForm() throws {
        let text = """
        Ship the beta build

        ## Goal
        Get the beta to testers.

        **Done means**
        - build uploaded
        - notes published

        **Current status:** waiting on review

        Owner decisions: none recorded
        Pull requests:
        - https://github.com/acme/pal/pull/12
        - https://github.com/acme/pal/pull/12.
        - (https://github.com/acme/pal/pull/14)
        - https://github.com/acme/pal/pull/13

        \(Self.marker)
        Key: faker-kit:pal:beta
        Ref: PAL-12
        """
        let document = KanbanBody.parse(text, title: "Ship the beta build")
        #expect(document.intro.isEmpty, "the title line is dropped and nothing else precedes the first label")
        #expect(document.parts.map(\.label) == [.goal, .doneMeans, .currentStatus, .ownerDecisions, .pullRequests])
        #expect(document.parts.map(\.id) == document.parts.map(\.label))
        #expect(part(.goal, in: document)?.blocks == [.paragraph("Get the beta to testers.")])
        #expect(part(.doneMeans, in: document)?.blocks == [.bullets(["build uploaded", "notes published"])])
        #expect(part(.currentStatus, in: document)?.blocks == [.paragraph("waiting on review")], "text after the colon is the first line")
        #expect(part(.ownerDecisions, in: document)?.blocks == [.paragraph("none recorded")])
        let pullRequests = try #require(part(.pullRequests, in: document))
        #expect(pullRequests.blocks.isEmpty, "links replace the text blocks")
        #expect(pullRequests.links == (try urls([
            "https://github.com/acme/pal/pull/12", "https://github.com/acme/pal/pull/14", "https://github.com/acme/pal/pull/13",
        ])), "trailing punctuation is stripped, repeats collapse, first-seen order stays")
        #expect(document.footer == ["Key: faker-kit:pal:beta", "Ref: PAL-12"])
        #expect(document.ref == "PAL-12")
        #expect(!document.isEmpty)
    }

    @Test("label titles and identifiers are the ones the views and tests rely on")
    func labelNames() {
        #expect(KanbanBodyLabel.allCases == [.goal, .doneMeans, .currentStatus, .ownerDecisions, .pullRequests])
        #expect(KanbanBodyLabel.allCases.map(\.identifier) == ["goal", "done-means", "current-status", "owner-decisions", "pull-requests"])
        #expect(KanbanBodyLabel.allCases.map(\.title) == ["Goal", "Done means", "Current status", "Owner decisions", "Pull requests"])
    }

    @Test("a label counts as a heading, bold or with a colon, in any case, and a bare word is prose", arguments: [
        "## Goal", "# Goal", "### Goal:", "**Goal**", "**Goal:**", "__Goal__", "**Goal**:", "Goal:", "goal:", "GOAL:", "- Goal:", "## **Goal**",
    ])
    func labelForms(_ line: String) {
        let document = KanbanBody.parse("\(line)\nship it")
        #expect(document.parts == [KanbanBodyPart(label: .goal, blocks: [.paragraph("ship it")])])
        #expect(document.intro.isEmpty)
    }

    @Test("bare words and bold phrases that merely start with a label name stay intro prose with no part")
    func notLabels() {
        let cases = [
            ("Goal\nship it", "Goal ship it"), ("**Goal** is to ship", "**Goal** is to ship"),
            ("Goals: many", "Goals: many"), ("Done: later", "Done: later"),
        ]
        for (text, expected) in cases {
            let document = KanbanBody.parse(text)
            #expect(document.intro == [.paragraph(expected)], "\(text) is prose")
            #expect(document.parts.isEmpty, "\(text) is not a label")
        }
    }

    @Test("aliases and inline text map onto the same parts")
    func aliases() throws {
        let document = KanbanBody.parse("""
        Goal: ship it
        Done when: tests pass
        Status: running
        Owner decisions: none
        Pull request: https://github.com/acme/pal/pull/3
        """)
        #expect(document.parts.map(\.label) == [.goal, .doneMeans, .currentStatus, .ownerDecisions, .pullRequests])
        #expect(part(.doneMeans, in: document)?.blocks == [.paragraph("tests pass")])
        #expect(part(.currentStatus, in: document)?.blocks == [.paragraph("running")])
        #expect(part(.pullRequests, in: document)?.links == (try urls(["https://github.com/acme/pal/pull/3"])))
    }

    @Test("a label that appears twice concatenates in order, and with no label the whole body is intro")
    func repeatedAndUnlabelled() {
        let repeated = KanbanBody.parse("Goal: one\n\nOwner decisions: x\n\nGoal: two")
        #expect(part(.goal, in: repeated)?.blocks == [.paragraph("one"), .paragraph("two")])
        #expect(part(.ownerDecisions, in: repeated)?.blocks == [.paragraph("x")])
        let plain = KanbanBody.parse("Just some words\nmore of them")
        #expect(plain.intro == [.paragraph("Just some words more of them")])
        #expect(plain.parts.isEmpty)
    }

    @Test("text before the first label is the intro, minus a leading line that equals the title")
    func introBeforeLabels() {
        let lead = KanbanBody.parse("Why this exists.\n\nGoal: ship it")
        #expect(lead.intro == [.paragraph("Why this exists.")])
        #expect(lead.parts == [KanbanBodyPart(label: .goal, blocks: [.paragraph("ship it")])], "the intro is not merged into the goal")
        let titled = KanbanBody.parse("repo-setup\nGoal: x", title: "repo-setup")
        #expect(titled.intro.isEmpty)
        #expect(titled.parts == [KanbanBodyPart(label: .goal, blocks: [.paragraph("x")])])
        let marked = KanbanBody.parse("## **Repo-Setup**\nGoal: x", title: "repo-setup")
        #expect(marked.intro.isEmpty, "markup and case do not defeat the title match")
        #expect(KanbanBody.parse("\n\nrepo-setup\n\nWhy.\nGoal: x", title: "repo-setup").intro == [.paragraph("Why.")], "leading blanks are skipped")
        #expect(KanbanBody.parse("repo-setup\nGoal: x").intro == [.paragraph("repo-setup")], "without a title the first line is kept")
        let other = KanbanBody.parse("Other words\nGoal: x", title: "repo-setup")
        #expect(other.intro == [.paragraph("Other words")], "a first line that is not the title stays")
    }

    @Test("a leading slash command is ordinary intro text, with or without a title")
    func slashCommandIsText() {
        #expect(KanbanBody.parse("/faker-mode\nGoal: x").intro == [.paragraph("/faker-mode")])
        #expect(KanbanBody.parse("/ not a command\nGoal: x").intro == [.paragraph("/ not a command")])
        let titled = KanbanBody.parse("/faker-mode\nShip the beta build\n\nGoal: x", title: "Ship the beta build")
        #expect(titled.intro == [.paragraph("/faker-mode Ship the beta build")], "the title is only dropped when it leads")
        #expect(KanbanBody.parse("/faker-mode\n\nrepo-setup\n", title: "Repo-Setup").intro == [.paragraph("/faker-mode"), .paragraph("repo-setup")])
    }

    @Test("a Unit of line after the title is intro text, with no title guessing")
    func unitOfIsText() {
        let untitled = KanbanBody.parse("repo-setup\nUnit of pal, run by pal.\nStatus: done")
        #expect(untitled.intro == [.paragraph("repo-setup Unit of pal, run by pal.")])
        let titled = KanbanBody.parse("repo-setup\nUnit of pal, run by pal.\nStatus: done", title: "repo-setup")
        #expect(titled.intro == [.paragraph("Unit of pal, run by pal.")])
        #expect(part(.currentStatus, in: titled)?.blocks == [.paragraph("done")])
    }

    @Test("the old repo-setup body keeps its prose as intro, its labels as parts, and the rest in the footer with the ref")
    func oldForm() throws {
        let text = """
        repo-setup
        Unit of smilewallpaper, run by smilewallpaper; serves no chief part.
        Owner decisions: none recorded
        Pull requests: https://github.com/TitoniumLab/SmileWallpaper/pull/1
        Sessions: none yet
        Status: in-progress; not waiting; updated 2026-11-17 02:29 UTC
        \(Self.marker)
        Key: faker-kit:smilewallpaper:repo-setup
        Kind: unit
        Project: smilewallpaper
        Bot: smilewallpaper
        Outcome: merged-pr
        PRs: 1
        Added: 2026-11-17 01:00 UTC
        Updated: 2026-11-17 02:29 UTC
        History: created; claimed
        Ref: FREN-3
        """
        let document = KanbanBody.parse(text, title: "repo-setup")
        let links = try urls(["https://github.com/TitoniumLab/SmileWallpaper/pull/1"])
        #expect(document.intro == [.paragraph("Unit of smilewallpaper, run by smilewallpaper; serves no chief part.")])
        #expect(document.parts == [
            KanbanBodyPart(label: .currentStatus, blocks: [.paragraph("in-progress; not waiting; updated 2026-11-17 02:29 UTC")]),
            KanbanBodyPart(label: .ownerDecisions, blocks: [.paragraph("none recorded")]),
            KanbanBodyPart(label: .pullRequests, blocks: [], links: links),
        ])
        #expect(document.parts.allSatisfy { !$0.blocks.isEmpty || !$0.links.isEmpty }, "no empty part")
        #expect(part(.pullRequests, in: document)?.links.count == 1)
        #expect(document.footer == [
            "Sessions: none yet",
            "Key: faker-kit:smilewallpaper:repo-setup", "Kind: unit", "Project: smilewallpaper", "Bot: smilewallpaper",
            "Outcome: merged-pr", "PRs: 1", "Added: 2026-11-17 01:00 UTC", "Updated: 2026-11-17 02:29 UTC", "History: created; claimed",
            "Ref: FREN-3",
        ])
        #expect(document.ref == "FREN-3")
        #expect(!document.isEmpty)
    }

    @Test("pull requests without a link keep their text, and an empty part is omitted")
    func pullRequestsWithoutLinks() {
        let document = KanbanBody.parse("Goal: x\nPull requests: none yet\nOwner decisions:\nDone means:")
        #expect(part(.pullRequests, in: document)?.blocks == [.paragraph("none yet")])
        #expect(part(.pullRequests, in: document)?.links.isEmpty == true)
        #expect(document.parts.map(\.label) == [.goal, .pullRequests], "labels with no content are not parts")
    }

    @Test("a body of only labels with no content has no intro and no parts")
    func emptyLabelsOnly() {
        let document = KanbanBody.parse("Goal:\n## Done means\n**Owner decisions:**")
        #expect(document.parts.isEmpty)
        #expect(document.isEmpty)
    }

    @Test("the footer holds pre-marker machine lines first, then the marker region, and never the marker line")
    func footerExtraction() {
        let text = """
        Goal: ship it
        Key: k1
        - State: ready
        Sessions: none yet

        \(Self.marker)
        Kind: unit
        Free text that is not a field

        Goal: sneaky
        Status: sneaky
        ---- second marker ----
        """
        let document = KanbanBody.parse(text)
        #expect(document.footer == [
            "Key: k1", "- State: ready", "Sessions: none yet",
            "Kind: unit", "Free text that is not a field", "Goal: sneaky", "Status: sneaky", "---- second marker ----",
        ])
        #expect(document.parts == [KanbanBodyPart(label: .goal, blocks: [.paragraph("ship it")])], "nothing after the marker leaks into a part")
        #expect(document.intro.isEmpty, "nothing after the marker leaks into the intro")
    }

    @Test("the marker is matched on four dashes and the words machine fields, in any case; look-alikes are text")
    func markerMatching() {
        #expect(KanbanBody.parse("Goal: x\n---- FAKER-KIT MACHINE FIELDS ----\nKey: k").footer == ["Key: k"])
        #expect(KanbanBody.parse("Goal: x\n----machine fields\nKey: k").footer == ["Key: k"])
        let lookalikes = KanbanBody.parse("Goal: x\n--- machine fields ---\nThe machine fields are fine\n---- other ----")
        #expect(lookalikes.footer.isEmpty)
        #expect(lookalikes.parts == [KanbanBodyPart(label: .goal, blocks: [
            .paragraph("x --- machine fields --- The machine fields are fine ---- other ----"),
        ])])
    }

    @Test("a machine line inside a code fence stays code, not footer")
    func fencedMachineLine() {
        let document = KanbanBody.parse("Goal: run\n```\nKey: inside\n```")
        #expect(document.footer.isEmpty)
        #expect(part(.goal, in: document)?.blocks == [.paragraph("run"), .code("Key: inside")])
        let unlabelled = KanbanBody.parse("```\nKey: inside\n```")
        #expect(unlabelled.footer.isEmpty)
        #expect(unlabelled.intro == [.code("Key: inside")])
    }
}

@Suite("Kanban refs and search")
struct KanbanRefTests {
    private static let footer = "---- faker-kit machine fields (read by the kit, do not edit) ----"

    private func row(_ task: String, title: String = "", body: String?) throws -> KanbanCardRow {
        let card = KanbanCard(cardID: "g/b/\(task)", taskID: task, title: title, status: .ready)
        let json: JSONValue = [
            "state": "present", "scope": KanbanJSON.scope("g"),
            "detail": ["card": KanbanJSON.card(task), "body": body.map(JSONValue.string) ?? .null, "evidence": .array([]), "cursor": "c"],
        ]
        return KanbanCardRow(card: card, project: nil, detail: try #require(KanbanCardResult(json)?.detail))
    }

    private func refRow(_ task: String, ref: String, title: String = "Fix login") throws -> KanbanCardRow {
        try row(task, title: title, body: "Make login work.\n\(Self.footer)\nKey: k\nRef: \(ref)")
    }

    @Test("a ref is Ref: then letters, a dash and digits alone on its line, returned uppercased", arguments: [
        ("Ref: PAL-12", "PAL-12"), ("- Ref: PAL-12", "PAL-12"), ("**Ref:** PAL-12", "PAL-12"), ("* **Ref:** FREN-3", "FREN-3"),
        ("Ref:   PAL-12  ", "PAL-12"), ("Ref: PAL-1", "PAL-1"), ("Ref: FREN-3", "FREN-3"),
        ("Ref: pal-12", "PAL-12"), ("Ref: Pal-12", "PAL-12"), ("Ref: fren-3", "FREN-3"),
        ("Ref: A-1", "A-1"), ("Ref: PAL-1234567", "PAL-1234567"), ("Ref: ABCDEFGHIJKLM-1", "ABCDEFGHIJKLM-1"),
        ("Goal: x\nRef: AA-1\nRef: BB-2", "BB-2"), ("Ref: AA-1\nsome words after", "AA-1"),
    ])
    func refPresent(_ text: String, _ expected: String) {
        #expect(KanbanBody.ref(in: text) == expected)
        #expect(KanbanBody.parse(text).ref == expected)
    }

    @Test("anything that is not exactly a ref reads as no ref", arguments: [
        "", "Goal: x", "Ref:", "Ref: ", "Ref: PAL", "Ref: 12", "Ref: PAL-", "Ref: -12", "Ref: PAL-1x", "Ref: PAL-12 extra",
        "Ref: see PAL-12", "Ref: PAL-12-3", "Ref: A1-1", "Ref: PAL 12", "Ref: PAL_12", "Ref: PAL-\u{FF11}\u{FF12}",
        "Ref:PAL-12", "ref: PAL-12", "My Ref: PAL-12", "PAL-12",
    ])
    func refAbsent(_ text: String) {
        #expect(KanbanBody.ref(in: text) == nil)
        #expect(KanbanBody.parse(text).ref == nil)
        #expect(KanbanBody.ref(in: nil) == nil)
    }

    @Test("ranges finds letters-dash-digits refs of any case on word boundaries and nothing else")
    func ranges() {
        let text = "See PAL-12 and fren-3, also FREN-3, PAL-12x, a-1 and (ABCDEFGHIJKL-9)."
        #expect(KanbanRef.ranges(in: text).map { String(text[$0]) } == ["PAL-12", "fren-3", "FREN-3", "a-1", "ABCDEFGHIJKL-9"])
        #expect(KanbanRef.ranges(in: "").isEmpty)
        #expect(KanbanRef.ranges(in: "no refs here, PAL- or -7 or PAL12 or 12-3").isEmpty)
    }

    @Test("normalizing ignores case and the dash")
    func normalized() {
        #expect(KanbanRef.normalized("pal-12") == "PAL12")
        #expect(KanbanRef.normalized("PAL12") == "PAL12")
        #expect(KanbanRef.normalized("fren-3") == "FREN3")
        #expect(KanbanRef.normalized("-") == "")
    }

    @Test("a row has a ref only when its body carries a well-formed one, and it reads uppercased")
    func rowRef() throws {
        #expect(try refRow("t1", ref: "PAL-12").ref == "PAL-12")
        #expect(try refRow("t4", ref: "pal-12").ref == "PAL-12")
        #expect(try refRow("t5", ref: "PAL-1x").ref == nil)
        #expect(try row("t2", body: "plain words").ref == nil)
        #expect(try row("t3", body: nil).ref == nil)
    }

    @Test("search finds a card by its ref in any spelling, even when the ref is only in the footer and the title differs")
    func searchByRef() throws {
        let card = try refRow("t1", ref: "PAL-12", title: "Fix login")
        for term in ["PAL-12", "pal-12", "pal12", "PAL12", "Pal-1", "pal1", "login pal12"] {
            #expect(KanbanFilter(text: term).matches(card), "\(term) finds PAL-12")
        }
        for term in ["PAL-13", "pal2", "FREN-12", "pal12 missing", "pal-120"] {
            #expect(!KanbanFilter(text: term).matches(card), "\(term) does not find PAL-12")
        }
        let fren = try refRow("t6", ref: "fren-3", title: "Other work")
        for term in ["FREN-3", "fren-3", "fren3", "FREN", "fre", "Fren-"] {
            #expect(KanbanFilter(text: term).matches(fren), "\(term) finds FREN-3")
        }
        #expect(!KanbanFilter(text: "fren-30").matches(fren), "a longer number is another ref")
        let plain = try row("t2", title: "Palace twelve thing", body: "no ref in this one")
        #expect(!KanbanFilter(text: "pal12").matches(plain), "a card without a ref is not found by a ref spelling")
        #expect(!KanbanFilter(text: "-").matches(plain), "a lone dash is not a ref")
    }

    @Test("the ref index maps normalized refs to task ids, the first task id wins, and cards without a ref are absent")
    func index() throws {
        let rows = [
            try refRow("t2", ref: "PAL-12"), try refRow("t1", ref: "pal-12"), try refRow("t3", ref: "FREN-3"),
            try row("t4", body: "no ref"), try refRow("t5", ref: "PAL-1x"),
        ]
        #expect(KanbanRef.index(rows: rows) == ["PAL12": "t1", "FREN3": "t3"])
        #expect(KanbanRef.index(rows: []).isEmpty)
    }
}
