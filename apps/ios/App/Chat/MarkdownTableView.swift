import PalChat
import PalDesign
import SwiftUI

struct MarkdownTableView: View {
    let table: MarkdownTable
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var characterWidth: CGFloat = 7.5
    @ScaledMetric(relativeTo: .body) private var cellPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var minimumColumn: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var maximumColumn: CGFloat = 260

    private let corner: CGFloat = 8

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
        .background(PalTokens.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(PalTokens.divider, lineWidth: 1)
        }
        .accessibilityIdentifier("markdownTable")
    }

    private var widths: [CGFloat] {
        table.columnWidths(characterWidth: characterWidth, cellPadding: cellPadding, minimum: minimumColumn, maximum: maximumColumn)
    }

    private var grid: some View {
        let columnWidths = widths
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            row(table.header, widths: columnWidths, isHeader: true, isLast: table.rows.isEmpty)
            ForEach(table.rows.indices, id: \.self) { index in
                row(table.rows[index], widths: columnWidths, isHeader: false, isLast: index == table.rows.count - 1)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ cells: [AttributedString], widths: [CGFloat], isHeader: Bool, isLast: Bool) -> some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { column in
                cell(cells[column], width: widths[column], column: column, isHeader: isHeader, isLast: isLast)
            }
        }
    }

    private func cell(_ text: AttributedString, width: CGFloat, column: Int, isHeader: Bool, isLast: Bool) -> some View {
        InlineText(text: text, highlight: highlight, isCurrentMatch: isCurrentMatch, weight: isHeader ? .semibold : nil)
            .multilineTextAlignment(textAlignment(column))
            .padding(.horizontal, cellPadding)
            .padding(.vertical, cellPadding * 0.6)
            .frame(width: width, alignment: frameAlignment(column))
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(isHeader ? PalTokens.chipFill : Color.clear)
            .overlay(alignment: .bottom) {
                if !isLast { Rectangle().fill(PalTokens.divider).frame(height: 1) }
            }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
