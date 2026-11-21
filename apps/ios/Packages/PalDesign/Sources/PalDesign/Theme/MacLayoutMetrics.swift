import CoreGraphics

public struct MacShellAllocation: Equatable, Sendable {
    public let sidebar: CGFloat
    public let chat: CGFloat
    public let inspector: CGFloat

    public var chatOriginX: CGFloat { sidebar }
    public var inspectorOriginX: CGFloat { sidebar + chat }
}

public enum MacLayoutMetrics {
    public static let sidebarWidth: CGFloat = 280
    public static let sidebarWidthRange: ClosedRange<CGFloat> = 240...400
    public static let railWidth: CGFloat = 80
    public static let inspectorWidth: CGFloat = 320
    public static let chatColumnMin: CGFloat = 500
    public static let chatColumnMax: CGFloat = 960
    public static let settingsColumnWidth: CGFloat = 560
    public static let windowMin: CGFloat = sidebarWidthRange.upperBound + chatColumnMin
    public static let windowMinHeight: CGFloat = 600
    public static let defaultWindowWidth: CGFloat = 1280
    public static let defaultWindowHeight: CGFloat = 830

    public static func inspectorFits(window: CGFloat, sidebar: CGFloat) -> Bool {
        window - sidebar - inspectorWidth >= chatColumnMin
    }

    public static func allocate(window: CGFloat, sidebar: CGFloat, inspectorRequested: Bool) -> MacShellAllocation {
        let inspector = inspectorRequested && inspectorFits(window: window, sidebar: sidebar) ? inspectorWidth : 0
        return MacShellAllocation(sidebar: sidebar, chat: max(0, window - sidebar - inspector), inspector: inspector)
    }
}
