import CoreGraphics
import Foundation
import SwiftUI

public enum HermesMetrics {
    public static let screenMargin: CGFloat = 16
    public static let rowInset: CGFloat = 19
    public static let rowMinimumHeight: CGFloat = 48
    public static let rowVerticalPadding: CGFloat = 14
    public static let rowTextSpacing: CGFloat = 4
    public static let cardGap: CGFloat = 29
    public static let captionToCardGap: CGFloat = 8
    public static let separatorThickness: CGFloat = 1

    public static let cardRadius: CGFloat = 17
    public static let tileRadius: CGFloat = 15
    public static let sheetRadius: CGFloat = 39

    public static let circleButtonDiameter: CGFloat = 44
    public static let circleButtonStrokeWidth: CGFloat = 0.7
    public static let sheetHeaderTopPadding: CGFloat = 20
    public static let sheetHeaderHorizontalPadding: CGFloat = 20
    public static let sheetHeaderBottomGap: CGFloat = 34

    public static let chipHeight: CGFloat = 34
    public static let chipHorizontalPadding: CGFloat = 13
    public static let chipSpacing: CGFloat = 8

    public static let pillHeight: CGFloat = 34
    public static let pillHorizontalPadding: CGFloat = 13
    public static let largePillHeight: CGFloat = 48
    public static let largePillHorizontalPadding: CGFloat = 40

    public static let searchBarHeight: CGFloat = 48
    public static let searchBarHorizontalMargin: CGFloat = 28
    public static let searchBarLeadingButtonGap: CGFloat = 12

    public static let toggleTrackSize = CGSize(width: 63, height: 28)
    public static let toggleKnobSize = CGSize(width: 36, height: 24)
    public static let toggleKnobInset: CGFloat = 2

    public static let primaryBadgeDiameterRatio: CGFloat = 0.25
    public static let primaryBadgeRingRatio: CGFloat = 0.028
    public static let primaryBadgeCenterOffsetRatio: CGFloat = 0.386
}

public enum HermesTextStyle: CaseIterable, Sendable {
    case rowTitle
    case rowSubtitle
    case rowValue
    case sectionCaption
    case footnoteCaption
    case sheetTitle
    case botName
    case botPreview
    case timestamp
    case heroName
    case chip
    case pill
    case largePill
    case searchPrompt
    case version

    public var size: CGFloat {
        switch self {
        case .rowTitle, .rowValue, .sheetTitle: 15
        case .rowSubtitle, .version: 11
        case .sectionCaption, .footnoteCaption, .timestamp: 10.5
        case .botName: 15.5
        case .botPreview: 12.5
        case .heroName: 12
        case .chip: 13
        case .pill: 12.5
        case .largePill: 16
        case .searchPrompt: 17.5
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .largePill: .medium
        default: .regular
        }
    }

    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .rowTitle, .rowValue, .sheetTitle, .botName, .searchPrompt, .largePill: .body
        case .rowSubtitle, .botPreview, .heroName, .chip, .pill, .version: .footnote
        case .sectionCaption, .footnoteCaption, .timestamp: .caption
        }
    }
}

struct HermesTextModifier: ViewModifier {
    let style: HermesTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: HermesTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight))
    }
}

extension View {
    public func hermesText(_ style: HermesTextStyle) -> some View {
        modifier(HermesTextModifier(style: style))
    }
}
