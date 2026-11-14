import Foundation
import SwiftUI
import Testing
import PalDesign

@Suite("Inline text with many styled runs renders without exhausting the stack")
@MainActor
struct InlineTextComposerTests {
    private func render(_ text: Text) -> CGImage? {
        let renderer = ImageRenderer(content: text.frame(width: 390).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        return renderer.cgImage
    }

    @Test("a message with 2000+ find highlights renders")
    func manyHighlightRuns() {
        let body = AttributedString(String(repeating: "Estimate socket feature latency. ", count: 500))
        let highlighted = InlineTextComposer.highlight(body, query: "e", fill: .yellow, ink: .black)
        #expect(highlighted.runs.count >= 2000)
        let text = InlineTextComposer.compose(highlighted) { _ in Text(Image(systemName: "globe")) }
        #expect(render(text) != nil)
    }

    @Test("long markdown with many styled runs and links renders")
    func manyMarkdownRuns() throws {
        let line = "**bold** _it_ `code` [link](https://example.com/a) plain "
        let source = String(repeating: line, count: 400)
        let body = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let highlighted = InlineTextComposer.highlight(body, query: "i", fill: .yellow, ink: nil)
        #expect(highlighted.runs.count >= 2000)
        let text = InlineTextComposer.compose(highlighted) { _ in Text(Image(systemName: "globe")) }
        #expect(render(text) != nil)
    }
}
