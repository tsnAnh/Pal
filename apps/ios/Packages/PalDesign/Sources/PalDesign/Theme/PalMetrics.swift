import CoreGraphics
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum PalMetrics {
    public static let screenMargin: CGFloat = 16
    public static let rowInset: CGFloat = 19
    public static let rowMinimumHeight: CGFloat = 48
    public static let rowVerticalPadding: CGFloat = 14
    public static let rowTextSpacing: CGFloat = 4
    public static let cardGap: CGFloat = 29
    public static let captionToCardGap: CGFloat = 8
    public static let separatorThickness: CGFloat = 1

    public static let cardRadius: CGFloat = 12
    public static let tileRadius: CGFloat = 15

    public static let circleButtonDiameter: CGFloat = 44
    public static let circleButtonStrokeWidth: CGFloat = 0.7
    public static let sheetHeaderTopPadding: CGFloat = 20
    public static let sheetHeaderHorizontalPadding: CGFloat = 20
    public static let sheetHeaderBottomGap: CGFloat = 34
    public static let sheetCloseControlSize: CGFloat = 32
    public static let sheetGlassButtonSize: CGFloat = 33
    public static let sheetBottomInset: CGFloat = screenMargin
    public static let macPanelCloseTopInset: CGFloat = 8
    public static let macPanelCloseLeadingInset: CGFloat = 13
    public static let macPanelTitleClearance: CGFloat = sheetGlassButtonSize + 10

    public static let chipHeight: CGFloat = 34
    public static let chipHorizontalPadding: CGFloat = 13
    public static let chipSpacing: CGFloat = 8

    public static let pillHeight: CGFloat = 32
    public static let pillHorizontalPadding: CGFloat = 13
    public static let largePillHeight: CGFloat = 48
    public static let largePillHorizontalPadding: CGFloat = 40

    public static let searchBarHeight: CGFloat = 48
    public static let searchBarHorizontalMargin: CGFloat = 28
    public static let searchBarBottomPadding: CGFloat = -4
    public static let searchBarLeadingButtonGap: CGFloat = 12

    public static let homeHeaderTopPadding: CGFloat = 0
    public static let heroDiameter: CGFloat = 88
    public static let heroAvatarFrame: CGFloat = 127
    public static let heroNameGap: CGFloat = 10
    public static let heroRowSpacing: CGFloat = 22
    public static let heroTopPadding: CGFloat = 36
    public static let homeRowPitch: CGFloat = 66
    public static let homeRowAvatarFrame: CGFloat = 53
    public static let homeRowAvatarSlot: CGFloat = 44
    public static let homeRowInset: CGFloat = 16
    public static let homeRowTextGap: CGFloat = 2

    public static let pickerCell: CGFloat = 60
    public static let pickerShapeFrame: CGFloat = 51
    public static let swatchDiameter: CGFloat = 26
    public static let swatchSelectedDiameter: CGFloat = 36
    public static let swatchRowPitch: CGFloat = 43.5
    public static let swatchPitch: CGFloat = 60
    public static let createPreviewFrame: CGFloat = 201
    public static let createButtonHeight: CGFloat = 56
    public static let createPreviewBox: CGFloat = 138
    public static let nameFieldHeight: CGFloat = 53
    public static let nameFieldHorizontalMargin: CGFloat = 16

    public static let primaryBadgeDiameterRatio: CGFloat = 0.25
    public static let primaryBadgeRingRatio: CGFloat = 0.028
    public static let primaryBadgeCenterOffsetRatio: CGFloat = 0.386
}

public enum PalTextStyle: CaseIterable, Sendable {
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
        #if os(macOS)
        switch self {
        case .chatBody: 15
        case .composerField: 15
        case .chatStatus: 13
        case .botName: 14
        case .botPreview: 13
        case .timestamp: 12
        case .unreadLabel: 12
        case .chatCode: 12
        case .heroName: 11
        default: iosSize
        }
        #else
        iosSize
        #endif
    }

    private var iosSize: CGFloat {
        switch self {
        case .rowTitle, .rowValue, .sheetTitle: 15
        case .rowSubtitle, .version: 11
        case .sectionCaption, .footnoteCaption: 10.5
        case .timestamp: 12
        case .botName: 16
        case .botPreview: 13.5
        case .heroName: 11
        case .chip: 13
        case .pill: 12.5
        case .largePill: 16
        case .nameField: 20
        case .searchPrompt: 17.5
        case .chatBody: 15
        case .chatStatus: 15
        case .composerField: 16
        case .unreadLabel: 12
        case .chatCode: 13
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .largePill, .nameField: .medium
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

struct PalTextModifier: ViewModifier {
    let style: PalTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: PalTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight))
    }
}

public struct ChatLineBox: Equatable, Sendable {
    public let height: CGFloat
    public let baselineOffset: CGFloat

    public init(fontSize: CGFloat) {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: fontSize)
        #else
        let font = UIFont.systemFont(ofSize: fontSize)
        #endif
        height = (fontSize * ChatMetrics.bodyLineHeight / PalTextStyle.chatBody.size).rounded()
        baselineOffset = (height - font.ascender + font.descender) / 2
    }
}

struct ChatTextModifier: ViewModifier {
    let style: PalTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: PalTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        let line = ChatLineBox(fontSize: size)
        content
            .font(.system(size: size, weight: style.weight))
            .lineHeight(.exact(points: line.height))
            .baselineOffset(-line.baselineOffset)
    }
}

extension View {
    public func hermesText(_ style: PalTextStyle) -> some View {
        modifier(PalTextModifier(style: style))
    }

    public func chatText(_ style: PalTextStyle) -> some View {
        modifier(ChatTextModifier(style: style))
    }

    public func chatRowFrame(for sender: ChatSender) -> some View {
        frame(maxWidth: .infinity, alignment: ChatMetrics.rowAlignment(for: sender))
    }
}

public enum ChatSender: Sendable {
    case bot
    case user
    case system
}

public enum ChatMetrics {
    public static func rowAlignment(for sender: ChatSender) -> Alignment {
        switch sender {
        case .bot: .leading
        case .user: .trailing
        case .system: .center
        }
    }
    public static func bubbleColumnAlignment(_ side: HorizontalAlignment) -> Alignment {
        rowAlignment(for: side == .trailing ? .user : .bot)
    }
    public static let edgeMargin: CGFloat = 16
    public static let bubbleHorizontalPadding: CGFloat = 14
    public static let bubbleVerticalPadding: CGFloat = 9
    public static let bubbleRadius: CGFloat = 18
    #if os(macOS)
    public static let bubbleMaxWidth: CGFloat = 640
    #else
    public static let bubbleWidthFraction: CGFloat = 0.78
    public static let padColumn: CGFloat = 720
    #endif
    public static func bubbleWidth(inColumn column: CGFloat) -> CGFloat {
        #if os(macOS)
        min(column, bubbleMaxWidth)
        #else
        column * bubbleWidthFraction
        #endif
    }
    public static let sameSenderGap: CGFloat = 10
    public static let senderSwitchGap: CGFloat = 24
    public static let bubbleTrailingGap: CGFloat = 60
    public static let rowSpacing: CGFloat = 12
    #if os(macOS)
    public static let bodyLineHeight: CGFloat = 23
    public static let composerClearance: CGFloat = 24
    #else
    public static let bodyLineHeight: CGFloat = 22
    public static let composerClearance: CGFloat = 16
    #endif
    public static let blockSpacing: CGFloat = 10
    public static let bubbleCapsuleRadius: CGFloat = bodyLineHeight / 2 + bubbleVerticalPadding
    public static let separatorTopPadding: CGFloat = 20
    public static let separatorBottomPadding: CGFloat = 12
    public static let unreadTopPadding: CGFloat = 4
    public static let unreadBottomPadding: CGFloat = 8
    public static let unreadLabelGap: CGFloat = 12
    public static let unreadLineThickness: CGFloat = 1
    public static let statusIconSize: CGFloat = 12
    public static let statusLeadingInset: CGFloat = 24
    public static let statusTextGap: CGFloat = 8
    public static let composerHeight: CGFloat = 44
    public static let composerButtonDiameter: CGFloat = 34
    public static let composerInset: CGFloat = 8
    public static let headerButtonDiameter: CGFloat = 44
    public static let headerAvatarSize: CGFloat = 26
    public static let scrollButtonDiameter: CGFloat = 36
    public static let workingAvatarSize: CGFloat = 20
    public static let workingMoodPeriod: Double = 1.6
    public static let minimumHitTarget: CGFloat = {
        #if os(macOS)
        40
        #else
        44
        #endif
    }()
    public static let linkAvatarSize: CGFloat = 20
    public static let threadHeaderAvatarSize: CGFloat = 30
    public static let threadAvatarSize: CGFloat = 18
    public static let threadAvatarGap: CGFloat = 8
    public static let threadNameInset: CGFloat = 10
    public static let threadPillHeight: CGFloat = 36
}
