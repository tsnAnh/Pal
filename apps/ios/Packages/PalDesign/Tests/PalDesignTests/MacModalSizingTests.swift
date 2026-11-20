import CoreGraphics
@testable import PalDesign
import Testing

@Suite("Mac modal sizing")
struct MacModalSizingTests {
    @Test(arguments: [
        (CGSize(width: 900, height: 600), CGSize(width: 810, height: 540)),
        (CGSize(width: 1_280, height: 830), CGSize(width: 1_152, height: 747)),
        (CGSize(width: 1_728, height: 1_117), CGSize(width: 1_555, height: 1_005)),
    ])
    func aBigDialogTakesNinetyPercentOfTheWindowInBothAxes(window: CGSize, expected: CGSize) {
        #expect(MacModalSizing.frame(window: window) == expected)
    }

    @Test func theWindowMinimumKeepsTheFrameAtLeastEightHundredTenByFiveForty() {
        let minimum = CGSize(width: MacLayoutMetrics.windowMin, height: MacLayoutMetrics.windowMinHeight)
        let frame = MacModalSizing.frame(window: minimum)
        #expect(frame.width >= 810)
        #expect(frame.height >= 540)
    }

    @Test func aSmallDialogKeepsItsContentSizeInABigWindow() {
        let content = CGSize(width: MacModalSizing.createBotWidth, height: 571)
        #expect(MacModalSizing.fitted(content: content, window: CGSize(width: 1_280, height: 830)) == content)
    }

    @Test func aSmallDialogIsCappedAtNinetyPercentInBothAxes() {
        let content = CGSize(width: 1_300, height: 900)
        let window = CGSize(width: 900, height: 600)
        #expect(MacModalSizing.fitted(content: content, window: window) == CGSize(width: 810, height: 540))
        #expect(MacModalSizing.fitted(content: CGSize(width: 300, height: 900), window: window) == CGSize(width: 300, height: 540))
    }

    @Test func aFormColumnStopsAtSixHundredEightyAndFillsANarrowerPanel() {
        #expect(MacModalSizing.column(available: 1_100) == 680)
        #expect(MacModalSizing.column(available: 680) == 680)
        #expect(MacModalSizing.column(available: 590) == 590)
    }

    @Test func theConnectAppsGridHasThreeColumnsOnlyWhenThePanelIsWide() {
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 1_280, height: 830)).width) == 3)
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 900, height: 600)).width) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: 1_000) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: 1_001) == 3)
    }

    @Test func aSheetUsesTheWindowFrameOnceItIsMeasuredAndAFallbackBefore() {
        #expect(MacModalSizing.sheetSize(window: CGSize(width: 1_280, height: 830)) == CGSize(width: 1_152, height: 747))
        #expect(MacModalSizing.sheetSize(window: .zero) == MacModalSizing.sheetFallback)
    }

    @Test func theSizeNeverExceedsTheWindow() {
        for width in stride(from: CGFloat(900), through: 2_400, by: 37) {
            for height in stride(from: CGFloat(600), through: 1_400, by: 41) {
                let frame = MacModalSizing.frame(window: CGSize(width: width, height: height))
                #expect(frame.width <= width * 0.9 && frame.height <= height * 0.9)
                #expect(frame.width > width * 0.9 - 1 && frame.height > height * 0.9 - 1)
            }
        }
    }
}
