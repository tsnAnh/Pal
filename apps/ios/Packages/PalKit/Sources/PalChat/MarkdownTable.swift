import CoreGraphics
import Foundation

public struct MarkdownTable: Sendable, Hashable {
    public enum Alignment: Sendable, Hashable {
        case leading
        case center
        case trailing
    }

    public let alignments: [Alignment]
    public let header: [AttributedString]
    public let rows: [[AttributedString]]

    public var columnCount: Int { alignments.count }

    public init(alignments: [Alignment], header: [AttributedString], rows: [[AttributedString]]) {
        let count = alignments.isEmpty ? header.count : alignments.count
        self.alignments = alignments.isEmpty ? Array(repeating: .leading, count: count) : alignments
        self.header = Self.fitted(header, to: count)
        self.rows = rows.map { Self.fitted($0, to: count) }
    }

    public var plainText: String {
        ([header] + rows)
            .map { $0.map { String($0.characters) }.joined(separator: ", ") }
            .joined(separator: "\n")
    }

    private static func fitted(_ cells: [AttributedString], to count: Int) -> [AttributedString] {
        cells.count >= count ? Array(cells.prefix(count)) : cells + Array(repeating: AttributedString(), count: count - cells.count)
    }

    public var rowCount: Int { rows.count + 1 }

    public func copyTable(format: TableCopyFormat) -> String {
        switch format {
        case .markdown: markdownText
        case .tsv: tsvText
        }
    }

    private var markdownText: String {
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        func cell(_ text: AttributedString) -> String {
            String(text.characters).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        }
        let rule = alignments.map { alignment -> String in
            switch alignment {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        return ([line(header.map(cell)), line(rule)] + rows.map { line($0.map(cell)) }).joined(separator: "\n")
    }

    private var tsvText: String {
        func cell(_ text: AttributedString) -> String {
            String(text.characters).components(separatedBy: .newlines.union(CharacterSet(charactersIn: "\t"))).joined(separator: " ")
        }
        return ([header] + rows).map { $0.map(cell).joined(separator: "\t") }.joined(separator: "\n")
    }
}

public enum TableCopyFormat: Sendable, CaseIterable {
    case markdown
    case tsv
}

public enum TableColumnSizing {
    public static func widths(natural: [CGFloat], minimum: CGFloat, maximum: CGFloat, available: CGFloat?) -> [CGFloat] {
        let clamped = natural.map { min(max($0.rounded(.up), minimum), maximum) }
        let total = clamped.reduce(0, +)
        guard let available, total > 0, total < available else { return clamped }
        let scale = available / total
        var widths = clamped.map { ($0 * scale).rounded(.down) }
        widths[widths.count - 1] += available - widths.reduce(0, +)
        return widths
    }
}
