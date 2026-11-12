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

    public func columnWidths(characterWidth: CGFloat, cellPadding: CGFloat, minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
        (0..<columnCount).map { column in
            let longest = ([header] + rows).map { Self.longestLine(String($0[column].characters)) }.max() ?? 0
            let natural = CGFloat(longest) * characterWidth + cellPadding * 2
            return min(max(natural, minimum), maximum)
        }
    }

    private static func fitted(_ cells: [AttributedString], to count: Int) -> [AttributedString] {
        cells.count >= count ? Array(cells.prefix(count)) : cells + Array(repeating: AttributedString(), count: count - cells.count)
    }

    private static func longestLine(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
    }
}
