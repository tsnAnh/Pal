import PalChat
import PalDesign
import SwiftUI

struct MarkdownTableView: View {
    let table: MarkdownTable
    let highlight: String
    let isCurrentMatch: Bool
    var showsChrome = true

    @ScaledMetric(relativeTo: .body) private var cellPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var minimumColumn: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var maximumColumn: CGFloat = 260

    private let corner: CGFloat = 8

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
        .modifier(TableChrome(isOn: showsChrome, corner: corner))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdownTable")
    }

    private var grid: some View {
        TableGridLayout(columns: table.columnCount, minimum: minimumColumn, maximum: maximumColumn) {
            ForEach(table.header.indices, id: \.self) { column in
                cell(table.header[column], column: column, isHeader: true, isLast: table.rows.isEmpty)
            }
            ForEach(table.rows.indices, id: \.self) { index in
                ForEach(table.rows[index].indices, id: \.self) { column in
                    cell(table.rows[index][column], column: column, isHeader: false, isLast: index == table.rows.count - 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func cell(_ text: AttributedString, column: Int, isHeader: Bool, isLast: Bool) -> some View {
        InlineText(text: text, highlight: highlight, isCurrentMatch: isCurrentMatch, weight: isHeader ? .semibold : nil)
            .multilineTextAlignment(textAlignment(column))
            .padding(.horizontal, cellPadding)
            .padding(.vertical, cellPadding * 0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(column))
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

private struct TableChrome: ViewModifier {
    let isOn: Bool
    let corner: CGFloat

    func body(content: Content) -> some View {
        if isOn {
            content
                .background(PalTokens.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(PalTokens.divider, lineWidth: 1)
                }
        } else {
            content
        }
    }
}

private struct TableGridLayout: Layout {
    let columns: Int
    let minimum: CGFloat
    let maximum: CGFloat

    struct Metrics {
        var width: CGFloat?
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Metrics? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) -> CGSize {
        let metrics = resolve(proposal.width, subviews: subviews, cache: &cache)
        return CGSize(width: metrics.columnWidths.reduce(0, +), height: metrics.rowHeights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) {
        let metrics = resolve(proposal.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in metrics.rowHeights.enumerated() {
            var x = bounds.minX
            for (column, width) in metrics.columnWidths.enumerated() {
                subviews[row * columns + column].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height)
                )
                x += width
            }
            y += height
        }
    }

    private func resolve(_ width: CGFloat?, subviews: Subviews, cache: inout Metrics?) -> Metrics {
        if let cached = cache, cached.width == width { return cached }
        let metrics = measure(width, subviews: subviews)
        cache = metrics
        return metrics
    }

    private func measure(_ width: CGFloat?, subviews: Subviews) -> Metrics {
        guard columns > 0, subviews.count >= columns else { return Metrics(width: width) }
        let rows = subviews.count / columns
        let natural = (0..<columns).map { column in
            (0..<rows).map { subviews[$0 * columns + column].sizeThatFits(.unspecified).width }.max() ?? 0
        }
        let columnWidths = TableColumnSizing.widths(natural: natural, minimum: minimum, maximum: maximum, available: width)
        let rowHeights = (0..<rows).map { row in
            (0..<columns).map { column in
                subviews[row * columns + column].sizeThatFits(ProposedViewSize(width: columnWidths[column], height: nil)).height
            }.max() ?? 0
        }
        return Metrics(width: width, columnWidths: columnWidths, rowHeights: rowHeights)
    }
}

struct TableBubbleView: View {
    let table: MarkdownTable
    let highlight: String
    let isCurrentMatch: Bool

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTableView(table: table, highlight: highlight, isCurrentMatch: isCurrentMatch, showsChrome: false)
            footer
        }
        .background(BubblePalette.agentBubble, in: RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("^[\(table.rowCount) row](inflect: true) · ^[\(table.columnCount) column](inflect: true)")
            Spacer(minLength: 8)
            Menu("Copy table") {
                Button("Copy as Markdown") { Pasteboard.string = table.markdown }
                Button("Copy as TSV") { Pasteboard.string = table.tsv }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(PalTokens.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(PalTokens.divider).frame(height: 1) }
    }
}
