import CoreGraphics

public enum MacModalSizing {
    public static let windowFraction = 0.7
    public static let ceilingFraction = 0.9
    public static let floorSize = CGSize(width: 640, height: 440)
    public static let readableColumn: CGFloat = 680
    public static let alertTextWidth: CGFloat = 460
    public static let alertMinWidth: CGFloat = 320
    public static let createBotWidth: CGFloat = 440
    public static let renameBotWidth: CGFloat = 360
    public static let wideGridPanelWidth: CGFloat = 1_000
    public static let sheetFallback = CGSize(width: 560, height: 680)

    public static func frame(window: CGSize) -> CGSize {
        CGSize(
            width: share(of: window.width, floor: floorSize.width),
            height: share(of: window.height, floor: floorSize.height)
        )
    }

    public static func fitted(content: CGSize, window: CGSize) -> CGSize {
        let cap = frame(window: window)
        return CGSize(width: min(content.width, cap.width), height: min(content.height, cap.height))
    }

    public static func column(available: CGFloat) -> CGFloat {
        min(available, readableColumn)
    }

    public static func gridColumns(panelWidth: CGFloat) -> Int {
        panelWidth > wideGridPanelWidth ? 3 : 2
    }

    public static func sheetSize(window: CGSize) -> CGSize {
        window.width > 0 && window.height > 0 ? frame(window: window) : sheetFallback
    }

    private static func share(of length: CGFloat, floor: CGFloat) -> CGFloat {
        let wanted = max((length * CGFloat(windowFraction)).rounded(.down), floor)
        return min(wanted, (length * CGFloat(ceilingFraction)).rounded(.down))
    }
}
