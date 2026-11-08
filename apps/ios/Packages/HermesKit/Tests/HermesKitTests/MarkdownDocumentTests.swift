import Foundation
import HermesChat
import Testing

@Suite("Markdown document")
struct MarkdownDocumentTests {
    private func plain(_ block: MarkdownBlock) -> String {
        String(block.text.characters)
    }

    @Test func emptyAndWhitespaceProduceNoBlocks() {
        #expect(MarkdownDocument(parsing: "").blocks.isEmpty)
        #expect(MarkdownDocument(parsing: "  \n \n").blocks.isEmpty)
    }

    @Test func plainTextIsOneParagraph() {
        let document = MarkdownDocument(parsing: "Ok anh. Fren đã fix rồi.")
        #expect(document.blocks.count == 1)
        #expect(document.blocks[0].kind == .paragraph)
        #expect(plain(document.blocks[0]) == "Ok anh. Fren đã fix rồi.")
    }

    @Test func softLineBreaksStayLineBreaks() {
        let document = MarkdownDocument(parsing: "line one\nline two")
        #expect(plain(document.blocks[0]) == "line one\nline two")
    }

    @Test func boldAndInlineCodeKeepTheirIntent() {
        let block = MarkdownDocument(parsing: "a **bold** and `code` end").blocks[0]
        let bold = block.text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        let code = block.text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(bold.map { String(block.text[$0.range].characters) } == "bold")
        #expect(code.map { String(block.text[$0.range].characters) } == "code")
    }

    @Test func bulletListItemsEachStartAMarker() {
        let blocks = MarkdownDocument(parsing: "- one\n- two\n- three").blocks
        #expect(blocks.map(plain) == ["one", "two", "three"])
        #expect(blocks.allSatisfy { $0.startsListItem })
        #expect(blocks.allSatisfy { $0.lists == [ListMarker(style: .bullet, ordinal: $0.lists.first?.ordinal ?? 0)] })
    }

    @Test func orderedListKeepsOrdinals() {
        let blocks = MarkdownDocument(parsing: "1. a\n2. b\n3. c").blocks
        #expect(blocks.map { $0.lists.last?.ordinal } == [1, 2, 3])
        #expect(blocks.allSatisfy { $0.lists.last?.style == .ordered })
    }

    @Test func nestedListIncreasesDepth() {
        let blocks = MarkdownDocument(parsing: "1. outer\n   - inner a\n   - inner b").blocks
        #expect(blocks.map { $0.lists.count } == [1, 2, 2])
        #expect(blocks[1].lists.first?.style == .ordered)
        #expect(blocks[1].lists.last?.style == .bullet)
    }

    @Test func listItemWithTwoParagraphsMarksOnlyTheFirst() {
        let blocks = MarkdownDocument(parsing: "- first para\n\n  second para\n- next").blocks
        #expect(blocks.map(\.startsListItem) == [true, false, true])
    }

    @Test func codeBlockKeepsLanguageAndDropsTrailingNewline() {
        let block = MarkdownDocument(parsing: "```swift\nlet a = 1\nlet b = 2\n```").blocks[0]
        #expect(block.kind == .code(language: "swift"))
        #expect(plain(block) == "let a = 1\nlet b = 2")
    }

    @Test func unterminatedFenceWhileStreamingIsStillACodeBlock() {
        let blocks = MarkdownDocument(parsing: "Before\n\n```python\nprint(1)").blocks
        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .code(language: "python"))
        #expect(plain(blocks[1]) == "print(1)")
    }

    @Test func linksSurviveWithTheirDestination() {
        let block = MarkdownDocument(parsing: "xem [Google Payments](https://pay.google.com/x) nha").blocks[0]
        let link = block.text.runs.compactMap(\.link).first
        #expect(link == URL(string: "https://pay.google.com/x"))
        #expect(plain(block) == "xem Google Payments nha")
    }

    @Test func headingCarriesItsLevel() {
        let blocks = MarkdownDocument(parsing: "## Tiêu đề\n\nthân").blocks
        #expect(blocks[0].kind == .heading(level: 2))
        #expect(blocks[1].kind == .paragraph)
    }

    @Test func blockQuoteIsFlagged() {
        let blocks = MarkdownDocument(parsing: "> trích dẫn\n\nthường").blocks
        #expect(blocks.map(\.isQuoted) == [true, false])
    }

    @Test func unclosedEmphasisWhileStreamingDoesNotCrashOrDropText() {
        let block = MarkdownDocument(parsing: "một **chưa đóng").blocks[0]
        #expect(plain(block).contains("chưa đóng"))
    }

    @Test func blockIdentifiersAreStableWhenTextGrows() {
        let before = MarkdownDocument(parsing: "para one\n\npara tw").blocks.map(\.id)
        let after = MarkdownDocument(parsing: "para one\n\npara two and more").blocks.map(\.id)
        #expect(before == after)
    }
}
