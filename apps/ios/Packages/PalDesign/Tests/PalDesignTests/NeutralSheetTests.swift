import SwiftUI
import Testing
@testable import PalDesign

@Suite("Neutral sheet chrome")
struct NeutralSheetTests {
    @Test(
        "every mode paints window, sidebar, chat, list and sheet backgrounds from a neutral palette",
        arguments: AppearanceMode.allCases, [ColorScheme.dark, .light]
    )
    func backgroundsAreNeutral(mode: AppearanceMode, scheme: ColorScheme) {
        let palette = PalTheme(mode: mode, palette: mode.palette(systemScheme: scheme)).palette
        #expect([PalPalette.measuredDark, .derivedLight, .derivedBlack].contains(palette))
        for surface in [palette.canvas, palette.sheetBackground, palette.groupedCard, palette.chipFill] {
            #expect(surface.hueSaturationBrightness.saturation < 0.1)
        }
    }

    @Test("the toolbar row is exactly as tall as the close control, with the title and trailing on that row")
    func toolbarRowMetrics() {
        let row = SheetHeaderStyle.toolbarRow
        #expect(row.rowHeight == PalMetrics.sheetCloseControlSize)
        #expect(row.topPadding == 0)
        #expect(row.bottomGap == 0)
        #expect(row.titleFollowsLeadingButton)
        #expect(row.trailingFollowsTitle)
        #expect(SheetHeaderStyle.standard.rowHeight == nil)
        #expect(SheetHeaderStyle.standard.topPadding == PalMetrics.sheetHeaderTopPadding)
    }
}
