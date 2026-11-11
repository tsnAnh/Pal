import PalChat
import SwiftUI

struct RichBlockView: View {
    let block: MarkdownBlock
    let isStreaming: Bool

    var body: some View {
        let source = String(block.text.characters)
        if !block.isComplete {
            CodeBlockView(text: source)
        } else {
            switch RichRendering.kind(of: block) {
            case .code(let language): CodeCardView(source: source, language: language)
            case .diff: DiffBlockView(source: source)
            case .terminal: TerminalBlockView(source: source)
            case .json: JSONBlockView(source: source)
            case .latex: MathBlockView(source: source)
            case .mermaid: MermaidBlockView(source: source)
            case .plain: CodeBlockView(text: source)
            }
        }
    }
}
