import Foundation
import SwiftUI

public struct HermesPalette: Equatable, Sendable {
    public var canvas: RGB
    public var sheetBackground: RGB
    public var groupedCard: RGB
    public var cardStroke: RGB
    public var separator: RGB
    public var assistantBubble: RGB
    public var userBubble: RGB
    public var userBubbleText: RGB
    public var circleButtonFill: RGB
    public var circleButtonStroke: RGB
    public var chipFill: RGB
    public var chipText: RGB
    public var chipSelectedFill: RGB
    public var chipSelectedText: RGB
    public var glassCapsuleFill: RGB
    public var pillFill: RGB
    public var pillText: RGB
    public var pillDimmedText: RGB
    public var accentBlue: RGB
    public var accentBlueText: RGB
    public var destructive: RGB
    public var textPrimary: RGB
    public var textSecondary: RGB
    public var textTertiary: RGB
    public var sectionCaption: RGB
    public var chevron: RGB
    public var toggleOnTrack: RGB
    public var toggleOffTrack: RGB
    public var toggleKnob: RGB
    public var tileStroke: RGB
    public var primaryBadge: RGB
    public var primaryBadgeGlyph: RGB
    public var selectionRing: RGB
    public var workingDot: RGB
    public var unreadLine: RGB
}

extension HermesPalette {
    public static let measuredDark = HermesPalette(
        canvas: RGB(hex: 0x141414),
        sheetBackground: RGB(hex: 0x1c1c1c),
        groupedCard: RGB(hex: 0x272729),
        cardStroke: RGB(hex: 0x2f2f31),
        separator: RGB(hex: 0x2f2f31),
        assistantBubble: RGB(hex: 0x1d1d1d),
        userBubble: RGB(hex: 0x535353),
        userBubbleText: RGB(hex: 0xffffff),
        circleButtonFill: RGB(hex: 0x353535),
        circleButtonStroke: RGB(hex: 0x303030),
        chipFill: RGB(hex: 0x26252a),
        chipText: RGB(hex: 0xffffff),
        chipSelectedFill: RGB(hex: 0xfefefe),
        chipSelectedText: RGB(hex: 0x000000),
        glassCapsuleFill: RGB(hex: 0x303030),
        pillFill: RGB(hex: 0x26252a),
        pillText: RGB(hex: 0xffffff),
        pillDimmedText: RGB(hex: 0x7b7a7f),
        accentBlue: RGB(hex: 0x1c65cb),
        accentBlueText: RGB(hex: 0xffffff),
        destructive: RGB(hex: 0xe88b96),
        textPrimary: RGB(hex: 0xffffff),
        textSecondary: RGB(hex: 0x9b9b9e),
        textTertiary: RGB(hex: 0x515151),
        sectionCaption: RGB(hex: 0x575757),
        chevron: RGB(hex: 0x7b7b7e),
        toggleOnTrack: RGB(hex: 0xacabb0),
        toggleOffTrack: RGB(hex: 0x39393d),
        toggleKnob: RGB(hex: 0xfefeff),
        tileStroke: RGB(hex: 0x222222),
        primaryBadge: RGB(hex: 0xf58903),
        primaryBadgeGlyph: RGB(hex: 0xffffff),
        selectionRing: RGB(hex: 0x47474b),
        workingDot: RGB(hex: 0x3fa75c),
        unreadLine: RGB(hex: 0x25374f)
    )

    public static let derivedBlack: HermesPalette = {
        var palette = measuredDark
        palette.canvas = RGB(hex: 0x000000)
        palette.sheetBackground = RGB(hex: 0x000000)
        palette.groupedCard = RGB(hex: 0x1c1c1e)
        palette.cardStroke = RGB(hex: 0x2c2c2e)
        palette.separator = RGB(hex: 0x2c2c2e)
        palette.assistantBubble = RGB(hex: 0x161618)
        palette.glassCapsuleFill = RGB(hex: 0x1c1c1e)
        palette.chipFill = RGB(hex: 0x1c1c1e)
        palette.pillFill = RGB(hex: 0x1c1c1e)
        palette.tileStroke = RGB(hex: 0x2c2c2e)
        palette.toggleOffTrack = RGB(hex: 0x2c2c2e)
        palette.unreadLine = RGB(hex: 0x1a2a40)
        return palette
    }()

    public static let derivedLight = HermesPalette(
        canvas: RGB(hex: 0xffffff),
        sheetBackground: RGB(hex: 0xf2f2f7),
        groupedCard: RGB(hex: 0xffffff),
        cardStroke: RGB(hex: 0xe5e5ea),
        separator: RGB(hex: 0xe5e5ea),
        assistantBubble: RGB(hex: 0xf2f2f7),
        userBubble: RGB(hex: 0xe5e5ea),
        userBubbleText: RGB(hex: 0x000000),
        circleButtonFill: RGB(hex: 0xe5e5ea),
        circleButtonStroke: RGB(hex: 0xd1d1d6),
        chipFill: RGB(hex: 0xf2f2f7),
        chipText: RGB(hex: 0x000000),
        chipSelectedFill: RGB(hex: 0x000000),
        chipSelectedText: RGB(hex: 0xffffff),
        glassCapsuleFill: RGB(hex: 0xe9e9ee),
        pillFill: RGB(hex: 0xe5e5ea),
        pillText: RGB(hex: 0x000000),
        pillDimmedText: RGB(hex: 0xa1a1a6),
        accentBlue: RGB(hex: 0x1c65cb),
        accentBlueText: RGB(hex: 0xffffff),
        destructive: RGB(hex: 0xd70015),
        textPrimary: RGB(hex: 0x000000),
        textSecondary: RGB(hex: 0x6c6c70),
        textTertiary: RGB(hex: 0xaeaeb2),
        sectionCaption: RGB(hex: 0x8e8e93),
        chevron: RGB(hex: 0xc7c7cc),
        toggleOnTrack: RGB(hex: 0x3a3a3c),
        toggleOffTrack: RGB(hex: 0xe5e5ea),
        toggleKnob: RGB(hex: 0xffffff),
        tileStroke: RGB(hex: 0xd1d1d6),
        primaryBadge: RGB(hex: 0xf58903),
        primaryBadgeGlyph: RGB(hex: 0xffffff),
        selectionRing: RGB(hex: 0xc7c7cc),
        workingDot: RGB(hex: 0x3fa75c),
        unreadLine: RGB(hex: 0xb7cdf0)
    )

    struct Tint {
        let saturationScale: Double
        let brightnessLift: Double
    }

    static let surfaceTint = Tint(saturationScale: 0.55, brightnessLift: 0.05)
    static let canvasTint = Tint(saturationScale: 0.5, brightnessLift: 0.035)
    static let strokeTint = Tint(saturationScale: 0.4, brightnessLift: 0.08)

    public func tinted(toward accent: RGB) -> HermesPalette {
        func apply(_ color: RGB, _ tint: Tint) -> RGB {
            color.tinted(toward: accent, saturationScale: tint.saturationScale, brightnessLift: tint.brightnessLift)
        }
        var palette = self
        palette.canvas = apply(canvas, Self.canvasTint)
        palette.sheetBackground = apply(sheetBackground, Self.canvasTint)
        palette.groupedCard = apply(groupedCard, Self.surfaceTint)
        palette.assistantBubble = apply(assistantBubble, Self.surfaceTint)
        palette.circleButtonFill = apply(circleButtonFill, Self.surfaceTint)
        palette.chipFill = apply(chipFill, Self.surfaceTint)
        palette.pillFill = apply(pillFill, Self.surfaceTint)
        palette.glassCapsuleFill = apply(glassCapsuleFill, Self.surfaceTint)
        palette.cardStroke = apply(cardStroke, Self.strokeTint)
        palette.separator = apply(separator, Self.strokeTint)
        palette.circleButtonStroke = apply(circleButtonStroke, Self.strokeTint)
        palette.tileStroke = apply(tileStroke, Self.strokeTint)
        return palette
    }
}
