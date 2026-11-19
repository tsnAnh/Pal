import CoreGraphics
import Foundation
import PalChat
import Testing

@Suite("Message segments")
struct MessageSegmentsTests {
    private static let table = "| a | b |\n|---|---|\n| 1 | 2 |"

    private func segments(_ source: String, streaming: Bool = false) -> [MessageSegment] {
        MarkdownDocument(parsing: source, isStreaming: streaming).messageSegments
    }

    private func kinds(_ segments: [MessageSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text: "text"
            case .table: "table"
            }
        }
    }

    @Test func plainTextIsOneTextSegment() {
        #expect(kinds(segments("one\n\ntwo")) == ["text"])
        #expect(segments("").isEmpty)
    }

    @Test func textTableTextSplitsInOrder() {
        let result = segments("before\n\n\(Self.table)\n\nafter")
        #expect(kinds(result) == ["text", "table", "text"])
    }

    @Test func tableFirstAndTableLast() {
        #expect(kinds(segments("\(Self.table)\n\nafter")) == ["table", "text"])
        #expect(kinds(segments("before\n\n\(Self.table)")) == ["text", "table"])
        #expect(kinds(segments(Self.table)) == ["table"])
    }

    @Test func twoTablesStaySeparateBubbles() {
        let result = segments("\(Self.table)\n\nmid\n\n\(Self.table)")
        #expect(kinds(result) == ["table", "text", "table"])
        #expect(Set(result.map(\.id)).count == 3)
    }

    @Test func aTableStillStreamingBecomesItsOwnBubbleAndRowsAppend() {
        let header = "intro\n\n| a | b |\n|---|---|"
        let grown = "\(header)\n| 1 | 2 |\n| 3 | tw"
        let first = segments(header, streaming: true)
        let second = segments(grown, streaming: true)
        #expect(kinds(first) == ["text", "table"])
        #expect(kinds(second) == ["text", "table"])
        #expect(first.map(\.id) == second.map(\.id))
        guard case .table(_, let table) = second[1] else { Issue.record("no table"); return }
        #expect(table.rows.count == 2)
    }

    @Test func tablesInsideListsStayInline() {
        let cell = AttributedString("x")
        let table = MarkdownTable(alignments: [.leading], header: [cell], rows: [])
        let nested = MarkdownBlock(id: 1, kind: .table(table), text: AttributedString(), lists: [ListMarker(style: .bullet, ordinal: 1)])
        let top = MarkdownBlock(id: 2, kind: .table(table), text: AttributedString())
        let result = MessageSegment.split([.block(nested), .block(top)])
        #expect(kinds(result) == ["text", "table"])
    }

    @Test func textSegmentsKeepTheirSpokenText() {
        guard case .text(let segment) = segments("hello **world**\n\n- one\n- two")[0] else { Issue.record("no text"); return }
        #expect(segment.spoken == "hello world\none\ntwo")
    }

    @Test func documentTablesAreCollectedInOrder() {
        let document = MarkdownDocument(parsing: "\(Self.table)\n\ntext\n\n| c |\n|---|\n| 9 |")
        #expect(document.tables.count == 2)
        #expect(MarkdownDocument(parsing: "no table").tables.isEmpty)
    }
}

@Suite("Table copy and sizing")
struct TableCopyTests {
    private func table(_ source: String) -> MarkdownTable {
        MarkdownDocument(parsing: source).tables[0]
    }

    @Test func markdownKeepsAlignmentAndEscapesPipes() {
        let source = "| Run | Score | Note |\n|:---|---:|:---:|\n| A | 6.5 | a \\| b |"
        let text = table(source).markdown
        #expect(text == "| Run | Score | Note |\n| --- | ---: | :---: |\n| A | 6.5 | a \\| b |")
    }

    @Test func tsvJoinsCellsWithTabsAndRowsWithNewlines() {
        let text = table("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |").tsv
        #expect(text == "a\tb\n1\t2\n3\t4")
    }

    @Test func tsvFlattensTabsAndLineBreaksInsideACell() {
        let cell = AttributedString("x\ty\nz")
        let built = MarkdownTable(alignments: [.leading], header: [AttributedString("h")], rows: [[cell]])
        #expect(built.tsv == "h\nx y z")
        #expect(built.markdown.hasSuffix("| x\ty z |"))
    }

    @Test func rowAndColumnCountsIncludeTheHeader() {
        let counted = table("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        #expect(counted.rowCount == 3)
        #expect(counted.columnCount == 2)
    }

    @Test func naturalWidthsAreClampedToTheLimits() {
        let widths = TableColumnSizing.widths(natural: [12, 68.3, 1800], minimum: 50, maximum: 240, available: nil)
        #expect(widths == [50, 69, 240])
    }

    @Test func spareWidthIsSharedProportionallyAndFillsTheBubble() {
        let widths = TableColumnSizing.widths(natural: [100, 100, 200], minimum: 50, maximum: 240, available: 800)
        #expect(widths.reduce(0, +) == 800)
        #expect(widths[2] > widths[0])
    }

    @Test func tooWideTablesKeepTheirNaturalWidthsToScroll() {
        let widths = TableColumnSizing.widths(natural: [300, 300], minimum: 50, maximum: 240, available: 400)
        #expect(widths == [240, 240])
    }
}

@Suite("Selectable text runs")
struct SelectableRunTests {
    private func runs(_ source: String) -> [MarkdownRun] {
        MarkdownDocument(parsing: source).messageSegments.flatMap { segment -> [MarkdownRun] in
            if case .text(let text) = segment { text.runs } else { [] }
        }
    }

    @Test func headingsParagraphsAndListsShareOneRun() {
        let result = runs("# Title\n\nbody **bold**\n\n- one\n- two")
        #expect(result.count == 1)
        guard case .text(_, let text) = result[0] else { Issue.record("not text"); return }
        #expect(text.paragraphs.count == 4)
        #expect(text.paragraphs[0].style == .heading(level: 1))
        #expect(text.plainText == "Title\nbody bold\n•\tone\n•\ttwo")
    }

    @Test func codeBlocksSplitRunsAndKeepTheirOwnView() {
        let result = runs("before\n\n```swift\nlet x = 1\n```\n\nafter")
        #expect(result.count == 3)
        guard case .text = result[0], case .block(let code) = result[1], case .text = result[2] else { Issue.record("shape"); return }
        #expect(code.kind == .code(language: "swift"))
    }

    @Test func orderedListsKeepTheirNumbers() {
        guard case .text(_, let text) = runs("1. first\n2. second")[0] else { Issue.record("not text"); return }
        #expect(text.paragraphs.map(\.marker) == ["1.", "2."])
        #expect(text.paragraphs.allSatisfy { $0.listDepth == 1 })
    }

    @Test func nestedListsIncreaseTheDepth() {
        guard case .text(_, let text) = runs("- a\n  - b")[0] else { Issue.record("not text"); return }
        #expect(text.paragraphs.map(\.listDepth) == [1, 2])
    }

    @Test func linksSurviveInTheParagraphText() {
        guard case .text(_, let text) = runs("see [docs](https://example.com/a) now")[0] else { Issue.record("not text"); return }
        let links = text.paragraphs[0].text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com/a")!])
    }

    @Test func embedLinksStayOutsideTheSelectableRun() {
        let result = runs("see this\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ\n\nthanks")
        #expect(result.count == 3)
        guard case .block = result[1] else { Issue.record("embed should be its own block"); return }
    }

    @Test func quotesGroupTheirOwnRuns() {
        let result = runs("intro\n\n> quoted line\n\noutro")
        #expect(result.count == 3)
        guard case .quote(_, let inner) = result[1] else { Issue.record("not a quote"); return }
        #expect(inner.count == 1)
    }
}
