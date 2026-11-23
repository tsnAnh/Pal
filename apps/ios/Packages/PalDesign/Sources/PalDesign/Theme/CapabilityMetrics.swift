import CoreGraphics
import SwiftUI

public struct CapabilityMetrics: Equatable, Sendable {
    public let setKeyHeight: CGFloat
    public let setKeyTextSize: CGFloat
    public let addButtonHeight: CGFloat
    public let addButtonTextSize: CGFloat

    public static let onRowMinHeight: CGFloat = 52
    public static let limitedRowMinHeight: CGFloat = 76
    public static let statusIcon: CGFloat = 24
    public static let statusGlyph: CGFloat = 12
    public static let iconToTextGap: CGFloat = ConnectRowMetrics.tileToTextGap
    public static let textIndent: CGFloat = statusIcon + iconToTextGap
    public static let nameToStateGap: CGFloat = 8
    public static let reasonSize: CGFloat = 13
    public static let reasonLineLimit = 3
    public static let setKeySidePadding: CGFloat = 16
    public static let tapTarget: CGFloat = 44
    public static let addIconSize: CGFloat = 18
    public static let addIconGap: CGFloat = 8
    public static let addTopGap: CGFloat = 14
    public static let groupCaptionSize: CGFloat = 12
    public static let groupCaptionLeadingInset: CGFloat = 6
    public static let groupCaptionTopGap: CGFloat = 14
    public static let groupCaptionBottomGap: CGFloat = 6

    public static let mac = CapabilityMetrics(setKeyHeight: 32, setKeyTextSize: 14, addButtonHeight: 46, addButtonTextSize: 15)
    public static let phone = CapabilityMetrics(setKeyHeight: 36, setKeyTextSize: 15, addButtonHeight: 52, addButtonTextSize: 17)

    #if os(iOS)
    public static let isTouchPlatform = true
    #else
    public static let isTouchPlatform = false
    #endif

    public static func metrics(sizeClass: UserInterfaceSizeClass?) -> CapabilityMetrics {
        isTouchPlatform && sizeClass == .compact ? .phone : .mac
    }

    public static func hitOutset(visualHeight: CGFloat) -> CGFloat {
        isTouchPlatform ? max(0, (tapTarget - visualHeight) / 2) : 0
    }

    public static func rowMinHeight(hasDetail: Bool) -> CGFloat {
        hasDetail ? limitedRowMinHeight : onRowMinHeight
    }
}

private struct CapabilityButtonLabelModifier: ViewModifier {
    let sidePadding: CGFloat
    let fillsWidth: Bool
    @ScaledMetric private var height: CGFloat
    @ScaledMetric private var textSize: CGFloat

    init(height: CGFloat, textSize: CGFloat, sidePadding: CGFloat, fillsWidth: Bool) {
        self.sidePadding = sidePadding
        self.fillsWidth = fillsWidth
        _height = ScaledMetric(wrappedValue: height, relativeTo: .body)
        _textSize = ScaledMetric(wrappedValue: textSize, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: textSize))
            .padding(.horizontal, sidePadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
            .contentShape(Rectangle().inset(by: -CapabilityMetrics.hitOutset(visualHeight: height)))
    }
}

public extension View {
    func capabilityActionLabel(_ metrics: CapabilityMetrics) -> some View {
        modifier(CapabilityButtonLabelModifier(
            height: metrics.setKeyHeight, textSize: metrics.setKeyTextSize, sidePadding: CapabilityMetrics.setKeySidePadding, fillsWidth: false
        ))
    }

    func capabilityAddLabel(_ metrics: CapabilityMetrics) -> some View {
        modifier(CapabilityButtonLabelModifier(
            height: metrics.addButtonHeight, textSize: metrics.addButtonTextSize, sidePadding: CapabilityMetrics.setKeySidePadding, fillsWidth: true
        ))
    }
}
