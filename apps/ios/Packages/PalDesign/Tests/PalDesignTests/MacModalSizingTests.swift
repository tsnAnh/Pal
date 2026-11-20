import CoreGraphics
@testable import PalDesign
import Testing

@Suite("Mac modal sizing")
struct MacModalSizingTests {
    @Test(arguments: [
        (CGSize(width: 900, height: 600), CGSize(width: 640, height: 440)),
        (CGSize(width: 1_280, height: 830), CGSize(width: 896, height: 581)),
        (CGSize(width: 1_728, height: 1_117), CGSize(width: 1_209, height: 781)),
    ])
    func aBigDialogTakesSeventyPercentOfTheWindowInBothAxesAndNeverLessThanTheFloor(window: CGSize, expected: CGSize) {
        #expect(MacModalSizing.frame(window: window) == expected)
    }

    @Test func theWindowMinimumGetsTheFloorWhichIsAboveSeventyAndBelowNinetyPercent() {
        let minimum = CGSize(width: MacLayoutMetrics.windowMin, height: MacLayoutMetrics.windowMinHeight)
        let frame = MacModalSizing.frame(window: minimum)
        #expect(frame == MacModalSizing.floorSize)
        #expect(frame.width > minimum.width * MacModalSizing.windowFraction && frame.height > minimum.height * MacModalSizing.windowFraction)
        #expect(frame.width < minimum.width * MacModalSizing.ceilingFraction && frame.height < minimum.height * MacModalSizing.ceilingFraction)
    }

    @Test func aWindowSmallerThanTheFloorKeepsThePanelAtTheNinetyPercentCeiling() {
        #expect(MacModalSizing.frame(window: CGSize(width: 600, height: 400)) == CGSize(width: 540, height: 360))
    }

    @Test func aSmallDialogKeepsItsContentSizeInABigWindow() {
        let content = CGSize(width: MacModalSizing.createBotWidth, height: 571)
        #expect(MacModalSizing.fitted(content: content, window: CGSize(width: 1_280, height: 830)) == content)
    }

    @Test func aSmallDialogIsCappedAtTheSharedPanelSizeInBothAxes() {
        let content = CGSize(width: 1_300, height: 900)
        let window = CGSize(width: 1_280, height: 830)
        #expect(MacModalSizing.fitted(content: content, window: window) == CGSize(width: 896, height: 581))
        #expect(MacModalSizing.fitted(content: CGSize(width: 300, height: 900), window: window) == CGSize(width: 300, height: 581))
    }

    @Test func aFormColumnStopsAtSixHundredEightyAndFillsANarrowerPanel() {
        #expect(MacModalSizing.column(available: 1_100) == 680)
        #expect(MacModalSizing.column(available: 680) == 680)
        #expect(MacModalSizing.column(available: 590) == 590)
    }

    @Test func theConnectAppsGridHasThreeColumnsOnlyWhenThePanelIsWide() {
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 1_280, height: 830)).width) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 1_430, height: 900)).width) == 3)
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 900, height: 600)).width) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: 1_000) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: 1_001) == 3)
    }

    @Test func aSheetUsesTheWindowFrameOnceItIsMeasuredAndAFallbackBefore() {
        #expect(MacModalSizing.sheetSize(window: CGSize(width: 1_280, height: 830)) == CGSize(width: 896, height: 581))
        #expect(MacModalSizing.sheetSize(window: .zero) == MacModalSizing.sheetFallback)
    }

    @Test func theSizeStaysBetweenTheFloorAndTheCeilingAndTracksSeventyPercentAboveTheFloor() {
        for width in stride(from: CGFloat(900), through: 2_400, by: 37) {
            for height in stride(from: CGFloat(600), through: 1_400, by: 41) {
                let frame = MacModalSizing.frame(window: CGSize(width: width, height: height))
                #expect(frame.width >= MacModalSizing.floorSize.width && frame.height >= MacModalSizing.floorSize.height)
                #expect(frame.width <= width * MacModalSizing.ceilingFraction && frame.height <= height * MacModalSizing.ceilingFraction)
                if width * MacModalSizing.windowFraction >= MacModalSizing.floorSize.width {
                    #expect(frame.width > width * MacModalSizing.windowFraction - 1)
                }
                if height * MacModalSizing.windowFraction >= MacModalSizing.floorSize.height {
                    #expect(frame.height > height * MacModalSizing.windowFraction - 1)
                }
            }
        }
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 900, height: 600), CGSize(width: 1_280, height: 830), CGSize(width: 1_728, height: 1_117)])
    func aPanelHasAPositiveSizeInsideTheWindowAndTheGridHasAColumnEvenBeforeTheWindowIsMeasured(window: CGSize) {
        let panel = MacModalSizing.sheetSize(window: window)
        #expect(panel.width > 0 && panel.height > 0)
        if window != .zero {
            #expect(panel.width <= window.width * MacModalSizing.ceilingFraction && panel.height <= window.height * MacModalSizing.ceilingFraction)
        }
        #expect(MacModalSizing.gridColumns(panelWidth: panel.width) >= 1)
    }
}
