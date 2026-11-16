import PalKanban
import Testing

@Suite("Kanban body parser")
struct KanbanBodyTests {
    @Test("paragraphs, headings, lists and fenced code become blocks; inline markup stays in the text")
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
        #expect(document.blocks == [
            .paragraph("Intro with **bold**, `code` and [a link](https://example.test/x). Second line of the same paragraph."),
            .heading(level: 2, text: "Decisions"),
            .bullets(["first", "second continued", "third"]),
            .numbered(["one", "two"]),
            .code("let x = 1\n\nprint(x)"),
            .paragraph("Closing words"),
        ])
        #expect(document.metadata.isEmpty)
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
        #expect(document.blocks == [.paragraph("Write the release notes for the beta."), .paragraph("Note: this one is ordinary prose")])
        #expect(document.metadata == [
            "Key: PAL-12", "Kind: task", "- Project: pal", "**Bot:** alpha", "Outcome: merged_pr", "State: ready",
            "Added: 2026-11-01", "Updated: 2026-11-02", "History: created, claimed",
        ])
    }

    @Test("empty, missing and unterminated input is safe")
    func edges() {
        #expect(KanbanBody.parse(nil).isEmpty)
        #expect(KanbanBody.parse("  \n\n").isEmpty)
        #expect(KanbanBody.parse("```\nstill open").blocks == [.code("still open")])
        #expect(KanbanBody.parse("line one\r\nline two\r\n").blocks == [.paragraph("line one line two")])
        #expect(KanbanBody.parse("#nospace").blocks == [.paragraph("#nospace")])
        #expect(KanbanBody.parse("**bold** start").blocks == [.paragraph("**bold** start")])
    }
}
