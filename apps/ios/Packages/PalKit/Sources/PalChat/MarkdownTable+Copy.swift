import Foundation

public extension MarkdownTable {
    var markdown: String {
        let header = Self.markdownLine(header.map(Self.markdownCell))
        let divider = Self.markdownLine(alignments.map(Self.markdownDivider))
        let body = rows.map { Self.markdownLine($0.map(Self.markdownCell)) }
        return ([header, divider] + body).joined(separator: "\n")
    }

    var tsv: String {
        ([header] + rows)
            .map { $0.map(Self.tsvCell).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private static func markdownLine(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    private static func markdownDivider(_ alignment: Alignment) -> String {
        switch alignment {
        case .leading: "---"
        case .center: ":---:"
        case .trailing: "---:"
        }
    }

    private static func markdownCell(_ cell: AttributedString) -> String {
        flat(cell).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func tsvCell(_ cell: AttributedString) -> String {
        flat(cell).replacingOccurrences(of: "\t", with: " ")
    }

    private static func flat(_ cell: AttributedString) -> String {
        String(cell.characters)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

public extension MarkdownDocument {
    var tables: [MarkdownTable] {
        blocks.compactMap { block in
            if case .table(let table) = block.kind { table } else { nil }
        }
    }
}
