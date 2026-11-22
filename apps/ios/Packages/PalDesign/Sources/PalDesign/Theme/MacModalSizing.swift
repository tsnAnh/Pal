import CoreGraphics

public enum MacModalSizing {
    public static let windowFraction = 0.7
    public static let ceilingFraction = 0.9
    public static let heightCeilingFraction = 0.85
    public static let floorSize = CGSize(width: 640, height: 440)
    public static let readableColumn: CGFloat = 680
    public static let alertTextWidth: CGFloat = 460
    public static let alertMinWidth: CGFloat = 320
    public static let wideGridPanelWidth: CGFloat = 1_000
    public static let sheetFallback = CGSize(width: 560, height: 680)
    public static let anchoredBottomMargin: CGFloat = 24

    public static func frame(window: CGSize) -> CGSize {
        CGSize(
            width: share(of: window.width, floor: floorSize.width),
            height: share(of: window.height, floor: floorSize.height)
        )
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

public struct MacModalFrame: Sendable, Equatable {
    public let width: CGFloat
    public let maxHeight: CGFloat
    public let hugs: Bool
    public let topAnchor: CGFloat?

    public init(width: CGFloat, maxHeight: CGFloat, hugs: Bool, topAnchor: CGFloat? = nil) {
        self.width = width
        self.maxHeight = maxHeight
        self.hugs = hugs
        self.topAnchor = topAnchor
    }

    public var size: CGSize { CGSize(width: width, height: maxHeight) }
}

public enum MacModalSize: Sendable, Equatable, CaseIterable {
    case compact
    case form
    case stepper
    case wide
    case full
    case palette

    public func frame(in window: CGSize) -> MacModalFrame {
        let nominal = nominal(in: window)
        guard self != .full else { return nominal }
        guard window.width > 0, window.height > 0 else {
            return nominal.limited(width: .infinity, height: MacModalSizing.sheetFallback.height)
        }
        let heightCap = (window.height * CGFloat(MacModalSizing.heightCeilingFraction)).rounded(.down)
        let roomBelowAnchor = window.height - (nominal.topAnchor ?? 0) - MacModalSizing.anchoredBottomMargin
        return nominal.limited(
            width: (window.width * CGFloat(MacModalSizing.ceilingFraction)).rounded(.down),
            height: min(heightCap, nominal.topAnchor == nil ? heightCap : roomBelowAnchor)
        )
    }

    private func nominal(in window: CGSize) -> MacModalFrame {
        let panel = MacModalSizing.sheetSize(window: window)
        return switch self {
        case .compact: MacModalFrame(width: 440, maxHeight: .infinity, hugs: true)
        case .form: MacModalFrame(width: 560, maxHeight: .infinity, hugs: true)
        case .stepper: MacModalFrame(width: 540, maxHeight: 500, hugs: false)
        case .wide: MacModalFrame(width: 720, maxHeight: 600, hugs: true)
        case .palette: MacModalFrame(width: 640, maxHeight: .infinity, hugs: true, topAnchor: 120)
        case .full: MacModalFrame(width: panel.width, maxHeight: panel.height, hugs: false)
        }
    }
}

private extension MacModalFrame {
    func limited(width widthCap: CGFloat, height heightCap: CGFloat) -> MacModalFrame {
        MacModalFrame(width: min(width, widthCap), maxHeight: min(maxHeight, heightCap), hugs: hugs, topAnchor: topAnchor)
    }
}
