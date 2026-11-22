#if os(macOS)
import PalChat
import Testing

@testable import HermesBots

@Suite("Streaming code chunks")
struct StreamingCodeChunksTests {
    private static let sources = [
        "",
        "let a = 1",
        "let a = 1\n",
        "a\nb\nc\nd",
        "a\nb\nc\nd\n",
        "a\nb\nc\nd\ne",
        "a\nb\nc\nd\ne\n",
        "a\n\n\nd\n\n\n\nh\n\n",
        "/* one\ntwo\nthree\nfour\nfive */ let x = \"s\"\nlet y = 2\n",
        (0..<37).map { "let v\($0) = \($0)" }.joined(separator: "\n"),
        (0..<37).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n",
    ]

    private static func text(_ chunks: [[CodeSpan]]) -> String {
        chunks.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    private static func kinds(_ spans: [CodeSpan]) -> [String] {
        spans.flatMap { span in span.text.filter { $0 != "\n" }.map { "\($0)\(span.kind)" } }
    }

    @Test("chunks rejoin to the source", arguments: sources)
    func rejoinsToSource(source: String) {
        let chunks = StreamingCodeChunks(source: source, language: "swift").chunks
        #expect(Self.text(chunks) == source)
    }

    @Test("every chunk but the last holds exactly the chunk size", arguments: sources)
    func stableChunksAreFull(source: String) {
        let chunks = StreamingCodeChunks(source: source, language: "swift").chunks
        for chunk in chunks.dropLast() {
            #expect(chunk.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false).count == StreamingCodeChunks.linesPerChunk)
        }
    }

    @Test("a trailing empty line never forms a chunk of its own", arguments: sources)
    func tailIsNeverALoneEmptyLine(source: String) {
        let chunks = StreamingCodeChunks(source: source, language: "swift").chunks
        guard chunks.count > 1 else { return }
        #expect(!(chunks.last?.map(\.text).joined().isEmpty ?? true))
    }

    @Test("token colours are the highlighter's", arguments: sources)
    func keepsTokenKinds(source: String) throws {
        let spans = try #require(CodeHighlighter.spans(language: "swift", code: source))
        let chunks = StreamingCodeChunks(source: source, language: "swift").chunks
        #expect(Self.kinds(chunks.flatMap { $0 }) == Self.kinds(spans))
    }

    @Test("an unknown language stays one plain run per line", arguments: sources)
    func plainWithoutLanguage(source: String) {
        let chunks = StreamingCodeChunks(source: source, language: nil).chunks
        #expect(Self.text(chunks) == source)
        #expect(chunks.allSatisfy { $0.allSatisfy { $0.kind == .plain } })
    }
}
#endif
