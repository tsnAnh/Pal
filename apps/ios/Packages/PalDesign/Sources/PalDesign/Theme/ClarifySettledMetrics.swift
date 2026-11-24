import CoreGraphics

public enum ClarifySettledMetrics {
    public struct Entry: Equatable, Sendable {
        public var titleLines: Int
        public var rowLines: [Int]

        public init(titleLines: Int, rowLines: [Int]) {
            self.titleLines = titleLines
            self.rowLines = rowLines
        }
    }

    public static let surfacePadding: CGFloat = 16
    public static let titleToRows: CGFloat = 8
    public static let rowSpacing: CGFloat = 6
    public static let entrySpacing: CGFloat = 14
    public static let markWidth: CGFloat = 20
    public static let markGap: CGFloat = 10

    public static func titleWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - 2 * surfacePadding)
    }

    public static func rowTextWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, titleWidth(cardWidth: cardWidth) - markWidth - markGap)
    }

    public static func height(of entries: [Entry], titleLineHeight: CGFloat, rowLineHeight: CGFloat) -> CGFloat {
        let blocks = entries.map { entry -> CGFloat in
            let title = CGFloat(max(1, entry.titleLines)) * titleLineHeight
            let rows = entry.rowLines.map { CGFloat(max(1, $0)) * rowLineHeight }
            let spacing = CGFloat(max(0, rows.count - 1)) * rowSpacing
            return title + titleToRows + rows.reduce(0, +) + spacing
        }
        let gaps = CGFloat(max(0, blocks.count - 1)) * entrySpacing
        return 2 * surfacePadding + blocks.reduce(0, +) + gaps
    }
}
