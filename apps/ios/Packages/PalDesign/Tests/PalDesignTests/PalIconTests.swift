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

    @MainActor
    private func fittingSize(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    @Test("an icon takes exactly the room of the plain symbol, whatever its ink")
    @MainActor
    func iconAddsNoLayoutOfItsOwn() throws {
        let plain = try fittingSize(Image(systemName: "chevron.right").font(.system(size: 14)))
        #expect(plain.width > 0 && plain.height > 0)
        for ink in [PalIconInk.primary, .secondary, .tertiary, .destructive, .success, .onFill, .custom(.red)] {
            #expect(try fittingSize(PalIcon("chevron.right", ink: ink).font(.system(size: 14))) == plain)
        }
    }
}
