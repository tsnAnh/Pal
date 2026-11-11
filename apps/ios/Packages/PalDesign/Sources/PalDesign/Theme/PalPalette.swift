import Foundation
import SwiftUI

public struct PalPalette: Equatable, Sendable {
    public var canvas: RGB
    public var sheetBackground: RGB
    public var groupedCard: RGB
    public var cardStroke: RGB
    public var separator: RGB
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

extension PalPalette {
    public static let measuredDark = tokenPalette(isDark: true)

    public static let derivedBlack: PalPalette = {
        var palette = measuredDark
        palette.canvas = RGB(hex: 0x000000)
        palette.sheetBackground = RGB(hex: 0x000000)
        palette.groupedCard = RGB(hex: 0x1c1c1e)
        palette.cardStroke = RGB(hex: 0x2c2c2e)
        palette.separator = RGB(hex: 0x2c2c2e)
        palette.glassCapsuleFill = RGB(hex: 0x1c1c1e)
        palette.chipFill = RGB(hex: 0x1c1c1e)
        palette.pillFill = RGB(hex: 0x1c1c1e)
        palette.tileStroke = RGB(hex: 0x2c2c2e)
        palette.toggleOffTrack = RGB(hex: 0x2c2c2e)
        palette.unreadLine = RGB(hex: 0x1a2a40)
        return palette
    }()

    public static let derivedLight = tokenPalette(isDark: false)

    private static func tokenPalette(isDark: Bool) -> PalPalette {
        let canvas = RGB(hex: PalSwatches.content.ink(isDark: isDark).hex)
        let elevated = RGB(hex: PalSwatches.elevated.ink(isDark: isDark).hex)
        func solid(_ swatch: PalSwatch, over base: RGB? = nil) -> RGB {
            swatch.solid(isDark: isDark, over: base ?? canvas)
        }
        let inverseFill = solid(PalSwatches.inverseFill)
        let inverseText = solid(PalSwatches.inverseText)
        return PalPalette(
            canvas: canvas,
            sheetBackground: canvas,
            groupedCard: elevated,
            cardStroke: solid(PalSwatches.panelBorder, over: elevated),
            separator: solid(PalSwatches.divider, over: elevated),
            circleButtonFill: RGB(hex: PalSwatches.control.ink(isDark: isDark).hex),
            circleButtonStroke: solid(PalSwatches.borderStrong),
            chipFill: RGB(hex: PalSwatches.control.ink(isDark: isDark).hex),
            chipText: solid(PalSwatches.textPrimary),
            chipSelectedFill: inverseFill,
            chipSelectedText: inverseText,
            glassCapsuleFill: elevated,
            pillFill: RGB(hex: PalSwatches.control.ink(isDark: isDark).hex),
            pillText: solid(PalSwatches.textPrimary),
            pillDimmedText: solid(PalSwatches.textTertiary),
            accentBlue: RGB(hex: 0x1c65cb),
            accentBlueText: RGB(hex: 0xffffff),
            destructive: RGB(hex: isDark ? 0xe88b96 : 0xd70015),
            textPrimary: solid(PalSwatches.textPrimary),
            textSecondary: solid(PalSwatches.textSecondary),
            textTertiary: solid(PalSwatches.textTertiary),
            sectionCaption: solid(PalSwatches.textSecondary),
            chevron: solid(PalSwatches.textTertiary),
            toggleOnTrack: solid(PalSwatches.toggleOn),
            toggleOffTrack: solid(PalSwatches.toggleOff, over: elevated),
            toggleKnob: RGB(hex: 0xffffff),
            tileStroke: solid(PalSwatches.panelBorder),
            primaryBadge: RGB(hex: 0xf58903),
            primaryBadgeGlyph: RGB(hex: 0xffffff),
            selectionRing: solid(PalSwatches.borderStrong),
            workingDot: RGB(hex: 0x3fa75c),
            unreadLine: RGB(hex: isDark ? 0x25374f : 0xb7cdf0)
        )
    }

    struct Tint {
        let saturationScale: Double
        let brightnessLift: Double
    }

    static let surfaceTint = Tint(saturationScale: 0.55, brightnessLift: 0.05)
    static let canvasTint = Tint(saturationScale: 0.5, brightnessLift: 0.035)
    static let strokeTint = Tint(saturationScale: 0.4, brightnessLift: 0.08)

    public func tinted(toward accent: RGB) -> PalPalette {
        func apply(_ color: RGB, _ tint: Tint) -> RGB {
            color.tinted(toward: accent, saturationScale: tint.saturationScale, brightnessLift: tint.brightnessLift)
        }
        var palette = self
        palette.canvas = apply(canvas, Self.canvasTint)
        palette.sheetBackground = apply(sheetBackground, Self.canvasTint)
        palette.groupedCard = apply(groupedCard, Self.surfaceTint)
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
