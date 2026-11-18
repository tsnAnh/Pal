import PalKanban
import Testing

@Suite("Kanban body parser")
struct KanbanBodyTests {
    private static let marker = "---- faker-kit machine fields (read by the kit, do not edit) ----"

    private func intro(_ text: String, title: String? = nil) -> [KanbanBodyBlock] {
        KanbanBody.parse(text, title: title).intro
    }

    @Test("paragraphs, headings, lists and fenced code become intro blocks; inline markup stays in the text")
    func blocks() {
        let text = """
        Intro with **bold**, `code` and [a link](https://example.test/x).
        Second line of the same paragraph.

        ## Decisions

        - first
        - second
          continued
        * third

        1. one
        2) two

        ```swift
        let x = 1

        print(x)
        ```
        Closing words
        """
        let document = KanbanBody.parse(text)
        #expect(document.intro == [
            .paragraph("Intro with **bold**, `code` and [a link](https://example.test/x). Second line of the same paragraph."),
            .heading(level: 2, text: "Decisions"),
            .bullets(["first", "second continued", "third"]),
            .numbered(["one", "two"]),
            .code("let x = 1\n\nprint(x)"),
            .paragraph("Closing words"),
        ])
        #expect(document.parts.isEmpty, "no label means no part")
        #expect(document.footer.isEmpty)
        #expect(document.ref == nil)
        #expect(!document.isEmpty)
    }

    @Test("a body with only prose is intro blocks alone, with no parts, no footer and no ref")
    func proseOnly() {
        let text = """
        Plan the migration carefully.
        It touches three services.

        ## Why

        We want fewer moving parts. See **notes** and `code`.

        - first thing
        - second thing

        1. one
        2. two

        Final paragraph.
        """
        let document = KanbanBody.parse(text)
        #expect(document.intro == [
            .paragraph("Plan the migration carefully. It touches three services."),
            .heading(level: 2, text: "Why"),
            .paragraph("We want fewer moving parts. See **notes** and `code`."),
            .bullets(["first thing", "second thing"]),
            .numbered(["one", "two"]),
            .paragraph("Final paragraph."),
        ])
        #expect(document.parts.isEmpty)
        #expect(document.footer.isEmpty)
        #expect(document.ref == nil)
    }

    @Test("machine lines are set aside verbatim and never become blocks")
    func machineLines() {
        let text = """
        Write the release notes for the beta.

        Key: PAL-12
        Kind: task
        - Project: pal
        **Bot:** alpha
        Outcome: merged_pr
        State: ready
        Added: 2026-11-01
        Updated: 2026-11-02
        History: created, claimed
        Note: this one is ordinary prose
        """
        let document = KanbanBody.parse(text)
        #expect(document.intro == [.paragraph("Write the release notes for the beta."), .paragraph("Note: this one is ordinary prose")])
        #expect(document.footer == [
            "Key: PAL-12", "Kind: task", "- Project: pal", "**Bot:** alpha", "Outcome: merged_pr", "State: ready",
            "Added: 2026-11-01", "Updated: 2026-11-02", "History: created, claimed",
        ])
    }

    @Test("a body of only a footer has no intro and no parts but keeps its fields and ref")
    func footerOnly() {
        let marked = KanbanBody.parse("\(Self.marker)\nKey: k\nKind: unit\n\n  Ref: FREN-3  \n")
        #expect(marked.intro.isEmpty)
        #expect(marked.parts.isEmpty)
        #expect(marked.footer == ["Key: k", "Kind: unit", "Ref: FREN-3"])
        #expect(marked.isEmpty, "a footer alone is not content")
        #expect(marked.ref == "FREN-3")
        let loose = KanbanBody.parse("Key: k\nState: ready\nSessions: none yet")
        #expect(loose.isEmpty)
        #expect(loose.footer == ["Key: k", "State: ready", "Sessions: none yet"])
        #expect(loose.ref == nil)
    }

    @Test("a body of only the title line is an empty document, whatever the markup or case of that line")
    func titleOnly() {
        let empty = KanbanBodyDocument(parts: [])
        #expect(KanbanBody.parse("repo-setup", title: "repo-setup") == empty)
        #expect(KanbanBody.parse("\n\n  repo-setup  \n\n", title: "repo-setup") == empty)
        #expect(KanbanBody.parse("## **Repo-Setup**", title: "repo-setup") == empty)
        #expect(KanbanBody.parse("repo-setup", title: "  Repo-Setup ").isEmpty)
    }

    @Test("a title that is blank or differs from the first line drops nothing")
    func titleNotMatched() {
        #expect(intro("repo-setup", title: "") == [.paragraph("repo-setup")])
        #expect(intro("repo-setup", title: "  ") == [.paragraph("repo-setup")])
        #expect(intro("repo-setup", title: nil) == [.paragraph("repo-setup")])
        #expect(intro("repo-setup", title: "setup") == [.paragraph("repo-setup")], "only a whole-line match drops the line")
        #expect(intro("Intro\nrepo-setup", title: "repo-setup") == [.paragraph("Intro repo-setup")], "only a leading line is dropped")
    }

    @Test("empty, missing and whitespace-only input is an empty document")
    func emptyInput() {
        #expect(KanbanBody.parse(nil).isEmpty)
        #expect(KanbanBody.parse("").isEmpty)
        #expect(KanbanBody.parse("  \n\n").isEmpty)
        #expect(KanbanBody.parse(nil) == KanbanBodyDocument(parts: []))
    }

    @Test("unterminated fences, fenced labels, CRLF and look-alike markup stay intro text")
    func edges() {
        #expect(intro("```\nstill open") == [.code("still open")])
        #expect(intro("```\nGoal: inside a fence") == [.code("Goal: inside a fence")], "a label inside a code fence stays code")
        #expect(intro("line one\r\nline two\r\n") == [.paragraph("line one line two")])
        #expect(intro("#nospace") == [.paragraph("#nospace")])
        #expect(intro("**bold** start") == [.paragraph("**bold** start")])
        #expect(KanbanBody.parse("```\nGoal: inside a fence").parts.isEmpty)
    }
}
