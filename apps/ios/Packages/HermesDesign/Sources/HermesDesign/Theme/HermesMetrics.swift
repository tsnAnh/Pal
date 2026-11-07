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
    public static let searchBarBottomPadding: CGFloat = -4
    public static let searchBarLeadingButtonGap: CGFloat = 12

    public static let toggleTrackSize = CGSize(width: 63, height: 28)
    public static let toggleKnobSize = CGSize(width: 36, height: 24)
    public static let toggleKnobInset: CGFloat = 2

    public static let homeHeaderTopPadding: CGFloat = 0
    public static let heroDiameter: CGFloat = 88
    public static let heroAvatarFrame: CGFloat = 127
    public static let heroNameGap: CGFloat = 10
    public static let heroRowSpacing: CGFloat = 22
    public static let heroTopPadding: CGFloat = 36
    public static let homeRowPitch: CGFloat = 80
    public static let homeRowAvatarFrame: CGFloat = 63
    public static let homeRowAvatarSlot: CGFloat = 48
    public static let homeRowInset: CGFloat = 20
    public static let homeRowTextGap: CGFloat = 4

    public static let pickerCell: CGFloat = 60
    public static let pickerShapeFrame: CGFloat = 51
    public static let swatchDiameter: CGFloat = 26
    public static let swatchSelectedDiameter: CGFloat = 36
    public static let swatchRowPitch: CGFloat = 43.5
    public static let swatchPitch: CGFloat = 60
    public static let createPreviewFrame: CGFloat = 201
    public static let createPreviewBox: CGFloat = 138
    public static let createSheetDetentFraction: CGFloat = 0.948
    public static let nameFieldHeight: CGFloat = 53
    public static let nameFieldHorizontalMargin: CGFloat = 16
    public static let createButtonHeight: CGFloat = 48
    public static let createButtonBottomPadding: CGFloat = -4

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
    case nameField
    case chatBody
    case chatStatus
    case unreadLabel
    case composerField
    case chatCode

    public var size: CGFloat {
        switch self {
        case .rowTitle, .rowValue, .sheetTitle: 15
        case .rowSubtitle, .version: 11
        case .sectionCaption, .footnoteCaption, .timestamp: 10.5
        case .botName: 15.5
        case .botPreview: 12.5
        case .heroName: 11
        case .chip: 13
        case .pill: 12.5
        case .largePill: 16
        case .nameField: 20
        case .searchPrompt: 17.5
        case .chatBody: 15
        case .chatStatus, .composerField: 16
        case .unreadLabel: 11
        case .chatCode: 13.5
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .largePill, .nameField: .medium
        case .unreadLabel: .semibold
        default: .regular
        }
    }

    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .rowTitle, .rowValue, .sheetTitle, .botName, .searchPrompt, .largePill, .nameField, .chatBody, .chatStatus, .composerField: .body
        case .rowSubtitle, .botPreview, .heroName, .chip, .pill, .version: .footnote
        case .sectionCaption, .footnoteCaption, .timestamp, .unreadLabel: .caption
        case .chatCode: .footnote
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

public enum ChatMetrics {
    public static let edgeMargin: CGFloat = 16
    public static let bubbleHorizontalPadding: CGFloat = 14
    public static let bubbleVerticalPadding: CGFloat = 7
    public static let bubbleRadius: CGFloat = 19
    public static let bubbleTrailingGap: CGFloat = 60
    public static let rowSpacing: CGFloat = 12
    public static let bodyLineHeight: CGFloat = 20.3
    public static let separatorTopPadding: CGFloat = 14
    public static let separatorBottomPadding: CGFloat = 6
    public static let unreadTopPadding: CGFloat = 2
    public static let unreadBottomPadding: CGFloat = 9
    public static let unreadLabelGap: CGFloat = 11.5
    public static let unreadLineThickness: CGFloat = 1
    public static let statusDotDiameter: CGFloat = 7.5
    public static let statusDotSpacing: CGFloat = 3.3
    public static let statusLeadingInset: CGFloat = 23
    public static let statusTextGap: CGFloat = 11
    public static let composerHeight: CGFloat = 50
    public static let composerHorizontalMargin: CGFloat = 30
    public static let composerButtonDiameter: CGFloat = 34
    public static let composerInset: CGFloat = 8
    public static let headerButtonDiameter: CGFloat = 44
    public static let headerAvatarSize: CGFloat = 26
    public static let scrollButtonDiameter: CGFloat = 34
}
