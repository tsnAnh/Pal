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

    @Test(arguments: [
        (MacModalSize.compact, CGFloat(440)),
        (MacModalSize.form, CGFloat(560)),
        (MacModalSize.stepper, CGFloat(540)),
        (MacModalSize.wide, CGFloat(720)),
        (MacModalSize.full, CGFloat(896)),
        (MacModalSize.palette, CGFloat(640)),
    ])
    func eachSizeClassHasItsOwnWidthInATypicalWindow(size: MacModalSize, width: CGFloat) {
        #expect(size.frame(in: CGSize(width: 1_280, height: 830)).width == width)
    }

    @Test(arguments: [CGSize(width: 1_280, height: 830), CGSize(width: 1_728, height: 1_117), CGSize(width: 900, height: 600)])
    func compactAndFormHugTheirContentUpToEightyFivePercentOfTheWindowHeight(window: CGSize) {
        let cap = (window.height * 0.85).rounded(.down)
        for size in [MacModalSize.compact, .form] {
            let frame = size.frame(in: window)
            #expect(frame.hugs)
            #expect(frame.maxHeight == cap)
            #expect(frame.topAnchor == nil)
        }
        #expect(MacModalSize.compact.frame(in: window).width == 440)
        #expect(MacModalSize.form.frame(in: window).width == 560)
    }

    @Test(arguments: [CGSize(width: 1_280, height: 830), CGSize(width: 1_728, height: 1_117), CGSize(width: 900, height: 720)])
    func aStepperKeepsOneFixedSizeSoStepsNeverResizeIt(window: CGSize) {
        #expect(MacModalSize.stepper.frame(in: window) == MacModalFrame(width: 540, maxHeight: 500, hugs: false))
    }

    @Test(arguments: [CGSize(width: 1_280, height: 830), CGSize(width: 1_728, height: 1_117), CGSize(width: 900, height: 720)])
    func aWidePanelHugsItsContentUpToSixHundred(window: CGSize) {
        #expect(MacModalSize.wide.frame(in: window) == MacModalFrame(width: 720, maxHeight: 600, hugs: true))
    }

    @Test func theFullPanelKeepsTheSharedSeventyPercentFrameInEveryWindow() {
        let windows = [CGSize(width: 900, height: 600), CGSize(width: 1_280, height: 830), CGSize(width: 1_728, height: 1_117), CGSize(width: 600, height: 400)]
        for window in windows {
            let shared = MacModalSizing.frame(window: window)
            #expect(MacModalSize.full.frame(in: window) == MacModalFrame(width: shared.width, maxHeight: shared.height, hugs: false))
        }
        #expect(MacModalSize.full.frame(in: CGSize(width: 1_280, height: 830)) == MacModalFrame(width: 896, maxHeight: 581, hugs: false))
    }

    @Test func thePaletteHugsAndSitsOneHundredTwentyFromTheTopAndGrowsWithResultsUpToTheWindowCap() {
        let frame = MacModalSize.palette.frame(in: CGSize(width: 1_280, height: 830))
        #expect(frame == MacModalFrame(width: 640, maxHeight: 686, hugs: true, topAnchor: 120))
        let tall = MacModalSize.palette.frame(in: CGSize(width: 1_728, height: 1_117))
        #expect(tall.maxHeight == 949)
        #expect(MacModalSize.allCases.filter { $0.frame(in: CGSize(width: 1_280, height: 830)).topAnchor != nil } == [.palette])
    }

    @Test func aPaletteInASmallWindowStaysInsideIt() {
        let window = CGSize(width: 900, height: 600)
        let frame = MacModalSize.palette.frame(in: window)
        #expect(frame.maxHeight == 456)
        #expect((frame.topAnchor ?? 0) + frame.maxHeight <= window.height)
    }

    @Test func aSmallWindowShrinksEveryClassBelowNinetyPercentWideAndEightyFivePercentTall() {
        let window = CGSize(width: 600, height: 400)
        #expect(MacModalSize.stepper.frame(in: window) == MacModalFrame(width: 540, maxHeight: 340, hugs: false))
        #expect(MacModalSize.wide.frame(in: window) == MacModalFrame(width: 540, maxHeight: 340, hugs: true))
        #expect(MacModalSize.form.frame(in: window) == MacModalFrame(width: 540, maxHeight: 340, hugs: true))
        #expect(MacModalSize.compact.frame(in: window).width == 440)
        #expect(MacModalSize.palette.frame(in: window).width == 540)
        for size in MacModalSize.allCases where size != .full {
            let frame = size.frame(in: window)
            #expect(frame.width <= 540 && frame.maxHeight <= 340)
        }
        #expect(MacModalSize.full.frame(in: window) == MacModalFrame(width: 540, maxHeight: 360, hugs: false))
    }

    @Test func beforeTheWindowIsMeasuredEachClassUsesItsNominalSize() {
        #expect(MacModalSize.compact.frame(in: .zero) == MacModalFrame(width: 440, maxHeight: MacModalSizing.sheetFallback.height, hugs: true))
        #expect(MacModalSize.form.frame(in: .zero).size == CGSize(width: 560, height: MacModalSizing.sheetFallback.height))
        #expect(MacModalSize.stepper.frame(in: .zero).size == CGSize(width: 540, height: 500))
        #expect(MacModalSize.wide.frame(in: .zero).size == CGSize(width: 720, height: 600))
        #expect(MacModalSize.full.frame(in: .zero).size == MacModalSizing.sheetFallback)
        #expect(MacModalSize.palette.frame(in: .zero).topAnchor == 120)
    }

    @Test func theConnectAppsGridHasThreeColumnsOnlyWhenThePanelIsWide() {
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 1_280, height: 830)).width) == 2)
        #expect(MacModalSizing.gridColumns(panelWidth: MacModalSizing.frame(window: CGSize(width: 1_440, height: 900)).width) == 3)
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
