import Foundation
import PalChat
import Testing

@Suite("Markdown rich blocks")
struct MarkdownRichTests {
    private func plain(_ block: MarkdownBlock) -> String {
        String(block.text.characters)
    }

    @Test func streamingOpenFenceMarksLastCodeBlockIncomplete() {
        let blocks = MarkdownDocument(parsing: "Before\n\n```swift\nlet a = 1", isStreaming: true).blocks
        #expect(blocks.map(\.id) == [0, 1])
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[1].kind == .code(language: "swift"))
        #expect(plain(blocks[1]) == "let a = 1")
        #expect(blocks.map(\.isComplete) == [true, false])
    }

    @Test func nonStreamingOpenFenceStaysCompleteCode() {
        let blocks = MarkdownDocument(parsing: "Before\n\n```swift\nlet a = 1").blocks
        #expect(blocks.last?.kind == .code(language: "swift"))
        #expect(blocks.allSatisfy { $0.isComplete })
    }

    @Test func streamingClosedFenceIsComplete() {
        let blocks = MarkdownDocument(parsing: "```py\nx = 1\n```", isStreaming: true).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].isComplete)
        #expect(plain(blocks[0]) == "x = 1")
    }

    @Test func streamingOpenFenceWithoutBodyYetStillShowsIncompleteBlock() {
        let blocks = MarkdownDocument(parsing: "```python", isStreaming: true).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: "python"))
        #expect(plain(blocks[0]).isEmpty)
        #expect(!blocks[0].isComplete)
    }

    @Test func closedBlocksFollowedByOpenOneOnlyLastIsIncomplete() {
        let source = "```a\n1\n```\n\ntext\n\n```b\n2"
        let blocks = MarkdownDocument(parsing: source, isStreaming: true).blocks
        #expect(blocks.map(\.kind) == [.code(language: "a"), .paragraph, .code(language: "b")])
        #expect(blocks.map(\.isComplete) == [true, true, false])
        #expect(plain(blocks[0]) == "1")
        #expect(plain(blocks[2]) == "2")
    }

    @Test func fenceNeedsAtLeastTheOpeningLengthToClose() {
        let blocks = MarkdownDocument(parsing: "~~~~\ncode ``` inside\n~~~", isStreaming: true).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: nil))
        #expect(!blocks[0].isComplete)
        #expect(plain(blocks[0]).contains("~~~"))
    }

    @Test func fourSpaceIndentIsNotAFence() {
        let blocks = MarkdownDocument(parsing: "    ```swift\n    foo", isStreaming: true).blocks
        #expect(blocks.allSatisfy { $0.isComplete })
    }

    @Test func backtickFenceInfoCannotContainBackticks() {
        let blocks = MarkdownDocument(parsing: "```a`b\ntext", isStreaming: true).blocks
        #expect(blocks.allSatisfy { $0.isComplete })
    }

    @Test func fenceIndentedUpToThreeSpacesStillCounts() {
        let blocks = MarkdownDocument(parsing: "   ```go\n   x := 1", isStreaming: true).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: "go"))
        #expect(!blocks[0].isComplete)
        #expect(plain(blocks[0]) == "x := 1")
    }

    @Test func streamingWithoutAnythingSpecialMatchesNonStreaming() {
        let source = "plain **text**\n\n- a\n- b"
        #expect(MarkdownDocument(parsing: source, isStreaming: true) == MarkdownDocument(parsing: source))
    }

    @Test func singleLineDisplayMath() {
        let blocks = MarkdownDocument(parsing: "before\n\n$$E = mc^2$$\n\nafter").blocks
        #expect(blocks.map(\.kind) == [.paragraph, .math, .paragraph])
        #expect(blocks.map(\.id) == [0, 1, 2])
        #expect(plain(blocks[1]) == "E = mc^2")
        #expect(blocks[1].isComplete)
        #expect(plain(blocks[0]) == "before")
        #expect(plain(blocks[2]) == "after")
    }

    @Test func multiLineDisplayMath() {
        let blocks = MarkdownDocument(parsing: "$$\n\\frac{a}{b}\n$$").blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .math)
        #expect(plain(blocks[0]) == "\\frac{a}{b}")
    }

    @Test func bracketDelimitedMath() {
        let single = MarkdownDocument(parsing: "\\[ a + b \\]").blocks
        #expect(single.map(\.kind) == [.math])
        #expect(plain(single[0]) == "a + b")
        let multi = MarkdownDocument(parsing: "intro\n\n\\[\nx^2\n\\]\n\noutro").blocks
        #expect(multi.map(\.kind) == [.paragraph, .math, .paragraph])
        #expect(plain(multi[1]) == "x^2")
    }

    @Test func twoMathBlocksGetSequentialIds() {
        let blocks = MarkdownDocument(parsing: "$$a$$\n\ntext\n\n$$b$$").blocks
        #expect(blocks.map(\.kind) == [.math, .paragraph, .math])
        #expect(blocks.map(\.id) == [0, 1, 2])
    }

    @Test func pricesAreNotMath() {
        let source = "It costs $5 and $10 today"
        let blocks = MarkdownDocument(parsing: source).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        #expect(plain(blocks[0]) == source)
    }

    @Test func inlineDoubleDollarMidLineIsNotABlock() {
        let blocks = MarkdownDocument(parsing: "so $$x$$ inline").blocks
        #expect(blocks.map(\.kind) == [.paragraph])
    }

    @Test func unbalancedDoubleDollarIsPlainTextWhenNotStreaming() {
        let blocks = MarkdownDocument(parsing: "$$ never closed\nmore text").blocks
        #expect(!blocks.contains { $0.kind == .math })
        #expect(blocks.map(plain).joined().contains("never closed"))
    }

    @Test func unbalancedDoubleDollarWhileStreamingIsIncompleteMath() {
        let blocks = MarkdownDocument(parsing: "intro\n\n$$\nx^2 + y", isStreaming: true).blocks
        #expect(blocks.map(\.kind) == [.paragraph, .math])
        #expect(plain(blocks[1]) == "x^2 + y")
        #expect(blocks.map(\.isComplete) == [true, false])
    }

    @Test func streamingMathThatLaterClosesBecomesComplete() {
        let blocks = MarkdownDocument(parsing: "$$\nx^2\n$$", isStreaming: true).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].isComplete)
    }

    @Test func unbalancedBracketMathStaysPlainEvenWhileStreaming() {
        let blocks = MarkdownDocument(parsing: "\\[ x + y", isStreaming: true).blocks
        #expect(!blocks.contains { $0.kind == .math })
    }

    @Test func mathInsideFencedCodeIsUntouched() {
        let blocks = MarkdownDocument(parsing: "```\n$$ x $$\n```").blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: nil))
        #expect(plain(blocks[0]) == "$$ x $$")
    }

    @Test func mathAfterAFenceIsStillRecognised() {
        let blocks = MarkdownDocument(parsing: "```\n$$ a $$\n```\n\n$$b$$").blocks
        #expect(blocks.map(\.kind) == [.code(language: nil), .math])
        #expect(plain(blocks[1]) == "b")
    }

    @Test func unclosedMathBeforeAFenceDoesNotSwallowIt() {
        let blocks = MarkdownDocument(parsing: "$$\nx\n```\ncode\n```").blocks
        #expect(blocks.contains { $0.kind == .code(language: nil) })
        #expect(!blocks.contains { $0.kind == .math })
    }

    @Test func crlfSourceSplitsMathLikeLf() {
        let blocks = MarkdownDocument(parsing: "a\r\n\r\n$$x$$\r\n\r\nb").blocks
        #expect(blocks.map(\.kind) == [.paragraph, .math, .paragraph])
        #expect(plain(blocks[1]) == "x")
    }

    @Test func emptyMathDelimitersAreNotMath() {
        #expect(!MarkdownDocument(parsing: "$$ $$").blocks.contains { $0.kind == .math })
    }

    @Test func richKindFollowsBlockKind() {
        let blocks = MarkdownDocument(parsing: "# Title\n\n```json\n{\"a\": 1}\n```\n\n```diff\n-a\n+b\n```\n\n```swift\nlet a = 1\n```\n\n$$x$$").blocks
        #expect(blocks.map(\.richKind) == [.plain, .json, .diff, .code(language: "swift"), .latex])
    }

    @Test func standaloneLinkNeedsASingleLinkRun() {
        func link(_ source: String) -> URL? { MarkdownDocument(parsing: source).blocks.first?.standaloneLink }
        #expect(link("[Watch](https://youtu.be/dQw4w9WgXcQ)") == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(link("https://youtu.be/dQw4w9WgXcQ") == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(link("see [x](https://a.example.com)") == nil)
        #expect(link("[a](https://a.example.com) and [b](https://b.example.com)") == nil)
        #expect(link("[mail](mailto:a@example.com)") == nil)
        #expect(link("- [x](https://a.example.com)") == nil)
        #expect(link("> [x](https://a.example.com)") == nil)
        #expect(link("hello") == nil)
        #expect(link("two words https://a.example.com") == nil)
    }
}
