import SwiftUI
import Testing
@testable import PalDesign

@Suite("Neutral sheet chrome")
struct NeutralSheetTests {
    @Test("a red bot accent leaves no tint once a surface drops the bot tint", arguments: AppearanceMode.allCases)
    func withoutBotTintIsNeutral(mode: AppearanceMode) throws {
        let red = try #require(RGB(hexString: "#f43f5e"))
        let tinted = PalTheme(mode: mode, palette: mode.palette(systemScheme: .dark, botAccent: red))
        let neutral = tinted.withoutBotTint(systemScheme: .dark)
        #expect(neutral.mode == mode)
        #expect(neutral.palette == mode.palette(systemScheme: .dark, botAccent: nil))
        if mode == .botColor {
            #expect(tinted.palette.sheetBackground != neutral.palette.sheetBackground)
            #expect(neutral.palette.sheetBackground == PalPalette.measuredDark.sheetBackground)
            #expect(neutral.palette.chipFill == PalPalette.measuredDark.chipFill)
        }
    }

    @Test("state colours survive the bot tint, so blocked and failing chips keep their red")
    func stateColoursAreNotTintTokens() throws {
        let red = try #require(RGB(hexString: "#f43f5e"))
        let tinted = PalPalette.measuredDark.tinted(toward: red)
        #expect(tinted.destructive == PalPalette.measuredDark.destructive)
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
