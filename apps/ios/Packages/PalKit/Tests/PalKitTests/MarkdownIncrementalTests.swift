@testable import PalChat
import Foundation
import Synchronization
import Testing

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private final class ParseCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func bump() { count.withLock { $0 += 1 } }
}

private func countingParser(_ counter: ParseCount) -> IncrementalMarkdown {
    IncrementalMarkdown(parseGroup: { text in
        counter.bump()
        return MarkdownDocument.parsedGroup(text)
    })
}

private func assertMatchesFullParse(_ incremental: IncrementalMarkdown, _ source: String, _ context: @autoclosure () -> String) {
    let streamed = incremental.document(for: source)
    let full = MarkdownDocument(parsing: source)
    #expect(streamed == full, Comment(rawValue: "blocks differ for \(context()): \(source.debugDescription)"))
    #expect(streamed.messageSegments == full.messageSegments, Comment(rawValue: "segments differ for \(context()): \(source.debugDescription)"))
}

private func assertEveryScalarPrefix(_ source: String) {
    let incremental = IncrementalMarkdown()
    var prefix = String.UnicodeScalarView()
    for scalar in source.unicodeScalars {
        prefix.append(scalar)
        assertMatchesFullParse(incremental, String(prefix), "scalar prefix \(prefix.count)")
    }
}

private func assertEveryPiece(_ pieces: [String], stride: Int = 1) {
    let incremental = IncrementalMarkdown()
    var source = ""
    for (index, piece) in pieces.enumerated() {
        source += piece
        if index % stride == 0 || index == pieces.count - 1 { assertMatchesFullParse(incremental, source, "piece \(index)") }
    }
}

private func words(_ source: String) -> [String] {
    var pieces: [String] = []
    var current = ""
    var inSpace = false
    for character in source {
        let isSpace = character.isWhitespace
        if inSpace, !isSpace {
            pieces.append(current)
            current = ""
        }
        inSpace = isSpace
        current.append(character)
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
}

private func stubSection(_ number: Int) -> String {
    let topic = "Subsystem \(number)"
    return [
        "## \(topic): render budget notes",
        "",
        "The \(topic.lowercased()) keeps a **steady frame budget** while the reply streams in, and each pass re-parses only the *tail* of the document.",
        "",
        "### Checklist for \(topic.lowercased())",
        "",
        "- Parse the growing tail instead of the whole reply on every chunk",
        "- Reuse identity for rows that already finished streaming",
        "- Record a signpost around pass \(number) so the trace shows its cost",
        "",
        "1. Receive the next delta from the gateway",
        "2. Append it to the live message and mark the tail dirty",
        "",
        "```swift",
        "func applyDelta\(number)(_ delta: String, to message: inout LiveMessage) {",
        "    message.text += delta",
        "}",
        "```",
        "",
        "```python",
        "def budget_\(number)(frame_ms: float) -> float:",
        "    return max(0.0, frame_ms - 16.7)",
        "```",
        "",
        "> A hitch is any frame that overruns the budget.",
        "",
        "| Pass | Work | Budget |",
        "| --- | --- | --- |",
        "| \(number)a | parse tail | 2 ms |",
        "",
    ].joined(separator: "\n")
}

private let edgeCases: [String] = [
    "# Title\n\nFirst paragraph with **bold** and `code`.\n\nSecond paragraph with a [link](https://example.com/a) inside.\n\nThird.",
    "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nBetween\n\n~~~\ncode ``` inside\n~~~\n\nAfter",
    "Intro\n\n````\n```\nnested\n```\n````\n\nAfter",
    "Open fence\n\n```python\nx = 1\n\n\ny = 2",
    "- one\n- two\n\n  continued item paragraph\n\n- three\n\nplain\n\n- again",
    "1. a\n\n2. b\n\n3. c\n\ntext\n\n5. e",
    "- outer\n  - inner\n    - deepest\n\n  back in outer\n\nend",
    "- item\n\n  ```sh\n  echo one\n\n  echo two\n  ```\n\n- next\n\nplain",
    "> quote one\n> still quote\n\n> second quote\n\nplain\n\n> third\n>\n> same quote",
    "> quote\n\n    indented code\n\n    more code\n\nplain",
    "para\n\n    indented code\n\n    more code\n\npara two",
    "| a | b |\n| --- | --- |\n| 1 | 2 |\n\ntext\n\n| c | d |\n|:-:|--:|\n| 3 | 4 |",
    "text\n\n| x | y |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\nmore text",
    "# H1\n\n## H2\n\n### H3\n\nSetext\n======\n\nSecond\n------\n\n---\n\n***\n\nend",
    "para\n\n<div>\nhtml\n\nstill html\n</div>\n\nafter",
    "para\n\n<!--\ncomment\n\nstill comment\n\nmore\n-->\n\nafter",
    "para\n\n<pre>\nfoo\n\nbar\n</pre>\n\nafter",
    "see [ref] here\n\nmore text\n\n[ref]: https://example.com\n\nlast",
    "[late] defined later\n\nfiller\n\n[late]: https://example.com/late",
    "Footnote[^1]\n\nbody\n\n[^1]: The note.",
    "Math before\n\n$$\nx^2 + y^2\n\nz\n$$\n\nafter math\n\nand \\[ a + b \\]",
    "line one\r\n\r\nline two\r\n\r\n```\r\ncode\r\n\r\nmore\r\n```\r\n\r\nend",
    "trailing  \n\nspaces here   \n\n   \n\nwhitespace line above\n\n\n\nmany blanks\n\n",
    "lazy\ncontinuation\nlines\n\nnext",
    "Emoji \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family\n\nflag \u{1F1EF}\u{1F1F5} done\n\ne\u{301} accent and \u{1F44D}\u{1F3FD} tone",
    "A link split [across chunk](https://exa\nmple.com/path) boundary\n\n[broken](https://example.com\n\nafter broken",
    "*emphasis\n\nnot closed**\n\n_under_ and __strong__\n\n~~strike~~ done",
    "\tTabbed paragraph\n\n\tTabbed code?\n\nnormal",
    "10. ten\n\n9) nine\n\ntext\n\n+ plus\n\n* star\n\n- dash",
    "- [ ] task\n- [x] done\n\nparagraph\n\n1986\\. escaped\n\nend",
    "a\n\n\n\n\nb\n\n\nc",
    "Line with ``` mid fence\n\nafter\n\n``` leading\n\nbody\n```\n\nend",
]

@Suite struct MarkdownIncrementalTests {
    @Test func everyScalarPrefixOfEachEdgeCaseMatchesAFullParse() {
        for source in edgeCases { assertEveryScalarPrefix(source) }
    }

    @Test func everyStreamedPieceOfTheStubReplyMatchesAFullParse() {
        let document = "# Streaming render stress reply\n\nThis reply is long on purpose.\n\n"
            + (1...6).map(stubSection).joined(separator: "\n")
        assertEveryPiece(words(document), stride: 2)
    }

    @Test func randomLineSoupMatchesAFullParseAtEveryLinePrefixAndMidLineCut() {
        let vocabulary = [
            "", "", "", "text", "more text here", "text  ", "**bold", "bold**", "*", "- a", "- b", "  - nested", "1. one", "2. two", "10) ten",
            "  indented", "    code", "\ttab", "> quote", ">", "> > nested", "| a | b |", "|---|---|", "| 1 | 2 |", "```", "```swift", "~~~", "````",
            "<div>", "</div>", "<!--", "-->", "[a]: http://x", "[a]", "# H", "## H2", "---", "===", "* * *", "***", "$$", "\\[", "\\]", "a\\", "   ",
            "\u{1F468}\u{200D}\u{1F469}", "caf\u{E9}", "[l](http://", "x)", "`code`", "``` mid", "1986\\. x", "+", "-", "= x",
        ]
        var generator = SeededGenerator(state: 0xC0FFEE)
        for round in 0..<220 {
            let lineCount = Int.random(in: 4...28, using: &generator)
            var lines: [String] = []
            for _ in 0..<lineCount { lines.append(vocabulary.randomElement(using: &generator)!) }
            let incremental = IncrementalMarkdown()
            for end in 1...lines.count {
                let source = lines[..<end].joined(separator: "\n")
                assertMatchesFullParse(incremental, source, "round \(round) lines \(end)")
                let last = lines[end - 1]
                if !last.isEmpty {
                    let cut = last.index(last.startIndex, offsetBy: Int.random(in: 0...last.count, using: &generator))
                    let partial = lines[..<(end - 1)].joined(separator: "\n") + (end > 1 ? "\n" : "") + last[..<cut]
                    assertMatchesFullParse(incremental, partial, "round \(round) lines \(end) partial")
                }
            }
        }
    }

    @Test func aGrowingReplyParsesOnlyItsOpenTailAfterTheFirstSnapshots() {
        let counter = ParseCount()
        let incremental = countingParser(counter)
        let paragraphs = (0..<12).map { "Paragraph number \($0) with **bold** text." }
        var source = ""
        var parsesPerSnapshot: [Int] = []
        for paragraph in paragraphs {
            source += (source.isEmpty ? "" : "\n\n") + paragraph
            let before = counter.value
            assertMatchesFullParse(incremental, source, "snapshot")
            parsesPerSnapshot.append(counter.value - before)
        }
        #expect(parsesPerSnapshot.dropFirst(2).allSatisfy { $0 == 1 })
    }

    @Test func aTextEditInsideEarlierBlocksReparsesFromThatBlockOn() {
        let counter = ParseCount()
        let incremental = countingParser(counter)
        _ = incremental.document(for: "one\n\ntwo\n\nthree\n\nfour")
        let before = counter.value
        let edited = "one\n\nTWO\n\nthree\n\nfour"
        #expect(incremental.document(for: edited) == MarkdownDocument(parsing: edited))
        #expect(counter.value - before == 3)
    }

    @Test func unsafeDocumentsFallBackToTheFullParseWithoutGroupParses() {
        let counter = ParseCount()
        let incremental = countingParser(counter)
        for source in ["a\n\n$$x$$\n\nb", "a\n\n[r]: http://x\n\nb", "a\r\n\r\nb", "a\n\n<div>\n\nb", "a\n\n  - ```\n\nb"] {
            #expect(incremental.document(for: source) == MarkdownDocument(parsing: source))
        }
        #expect(counter.value == 0)
    }

    @Test func blocksKeepTheirIdentityWhileTheTailGrows() {
        let incremental = IncrementalMarkdown()
        let first = incremental.document(for: "alpha\n\nbeta\n\ngam")
        let second = incremental.document(for: "alpha\n\nbeta\n\ngamma delta")
        #expect(Array(first.blocks.prefix(2)) == Array(second.blocks.prefix(2)))
        #expect(second.blocks.map(\.id) == [0, 1, 2])
    }
}
