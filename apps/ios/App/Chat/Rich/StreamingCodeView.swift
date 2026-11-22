#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct StreamingCodeChunks {
    static let linesPerChunk = 4

    let chunks: [[CodeSpan]]

    init(source: String, language: String?) {
        let lines = Self.lines(source: source, language: language)
        let size = Self.linesPerChunk
        var stable = (lines.count - 1) / size
        if stable > 0, lines.count - stable * size == 1, lines[lines.count - 1].isEmpty { stable -= 1 }
        var chunks = (0..<stable).map { Self.join(lines[$0 * size..<($0 + 1) * size]) }
        chunks.append(Self.join(lines[(stable * size)...]))
        self.chunks = chunks
    }

    private static func lines(source: String, language: String?) -> [[CodeSpan]] {
        let spans = CodeHighlighter.spans(language: language, code: source) ?? [CodeSpan(text: source, kind: .plain)]
        var lines: [[CodeSpan]] = []
        var current: [CodeSpan] = []
        for span in spans {
            var pieces = span.text.split(separator: "\n", omittingEmptySubsequences: false)[...]
            while let piece = pieces.popFirst() {
                if !piece.isEmpty { current.append(CodeSpan(text: String(piece), kind: span.kind)) }
                if !pieces.isEmpty {
                    lines.append(current)
                    current = []
                }
            }
        }
        lines.append(current)
        return lines
    }

    private static func join(_ lines: ArraySlice<[CodeSpan]>) -> [CodeSpan] {
        var joined: [CodeSpan] = []
        for (offset, line) in lines.enumerated() {
            if offset > 0 { joined.append(CodeSpan(text: "\n", kind: .plain)) }
            joined.append(contentsOf: line)
        }
        return joined
    }
}

struct StreamingCodeView: View {
    let source: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let chunks = StreamingCodeChunks(source: source, language: language).chunks
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chunks.indices, id: \.self) { index in
                CodeChunkText(spans: chunks[index], scheme: colorScheme).equatable()
            }
        }
        .textSelection(.enabled)
    }
}

private struct CodeChunkText: View, Equatable {
    let spans: [CodeSpan]
    let scheme: ColorScheme

    var body: some View {
        Text(highlighted)
            .hermesText(.chatCode)
            .font(RichCode.font)
            .foregroundStyle(PalTokens.textPrimary)
    }

    private var highlighted: AttributedString {
        let palette = RichPalette(scheme)
        var output = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if let color = palette.token(span.kind) { piece.foregroundColor = color }
            output.append(piece)
        }
        return output
    }
}
#endif
