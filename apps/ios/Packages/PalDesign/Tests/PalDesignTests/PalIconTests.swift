import SwiftUI
import Testing
@testable import PalDesign

@Suite("Icons resolve to the primary ink of the palette")
struct PalIconTests {
    private func luminance(_ rgb: RGB) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    private func primary(in palette: PalPalette) throws -> RGB {
        try #require(PalIconInk.primary.resolvedRGB(in: palette))
    }

    @Test("white-ish in the dark palettes")
    func darkPalettesGiveLightInk() throws {
        for palette in [PalPalette.measuredDark, .derivedBlack] {
            #expect(try luminance(primary(in: palette)) > 0.9)
        }
    }

    @Test("black-ish in the light palette")
    func lightPaletteGivesDarkInk() throws {
        #expect(try luminance(primary(in: .derivedLight)) < 0.15)
    }

    @Test("the primary ink is the palette's text colour, never an accent")
    func primaryIsTextPrimary() {
        for palette in [PalPalette.measuredDark, .derivedBlack, .derivedLight] {
            #expect(PalIconInk.primary.resolvedRGB(in: palette) == palette.textPrimary)
            #expect(PalIconInk.primary.resolvedRGB(in: palette) != palette.accentBlue)
        }
    }

    @Test("secondary and tertiary stay neutral palette inks")
    func hierarchyInksAreNeutral() {
        let palette = PalPalette.measuredDark
        #expect(PalIconInk.secondary.resolvedRGB(in: palette) == palette.textSecondary)
        #expect(PalIconInk.tertiary.resolvedRGB(in: palette) == palette.textTertiary)
    }
}
