import CoreGraphics
@testable import PalDesign
import Testing

@Suite("Mac shell width allocation")
struct MacLayoutMetricsTests {
    private static let windows: [CGFloat] = [900, 1_000, 1_100, 1_280]
    private static let sidebars: [CGFloat] = [
        MacLayoutMetrics.sidebarWidthRange.lowerBound,
        MacLayoutMetrics.sidebarWidth,
        MacLayoutMetrics.sidebarWidthRange.upperBound,
    ]

    @Test func theWindowMinimumHoldsTheWidestSidebarAndAUsableColumn() {
        #expect(MacLayoutMetrics.windowMin >= MacLayoutMetrics.sidebarWidthRange.upperBound + MacLayoutMetrics.chatColumnMin)
        #expect(MacLayoutMetrics.chatColumnMin <= MacLayoutMetrics.chatColumnMax)
    }

    @Test func atEveryWindowWidthTheSidebarKeepsItsWidthAndStaysOnScreen() {
        for window in Self.windows {
            for sidebar in Self.sidebars {
                let allocation = MacLayoutMetrics.allocate(window: window, sidebar: sidebar, inspectorRequested: true)
                #expect(allocation.sidebar == sidebar)
                #expect(allocation.chatOriginX >= 0)
                #expect(allocation.chatOriginX == sidebar)
            }
        }
    }

    @Test func theChatColumnNeverFallsBelowItsMinimumInAWindowAtOrAboveTheMinimum() {
        for window in Self.windows where window >= MacLayoutMetrics.windowMin {
            for sidebar in Self.sidebars {
                for requested in [false, true] {
                    let allocation = MacLayoutMetrics.allocate(window: window, sidebar: sidebar, inspectorRequested: requested)
                    #expect(allocation.chat >= MacLayoutMetrics.chatColumnMin)
                }
            }
        }
    }

    @Test func theInspectorCollapsesWhenItWouldStarveTheChatColumn() {
        let narrow = MacLayoutMetrics.allocate(window: 900, sidebar: MacLayoutMetrics.sidebarWidth, inspectorRequested: true)
        #expect(narrow.inspector == 0)
        #expect(narrow.chat == 900 - MacLayoutMetrics.sidebarWidth)
        let thousand = MacLayoutMetrics.allocate(window: 1_000, sidebar: MacLayoutMetrics.sidebarWidth, inspectorRequested: true)
        #expect(thousand.inspector == 0)
        let roomy = MacLayoutMetrics.allocate(window: 1_280, sidebar: MacLayoutMetrics.sidebarWidth, inspectorRequested: true)
        #expect(roomy.inspector == MacLayoutMetrics.inspectorWidth)
        #expect(roomy.chat == 1_280 - MacLayoutMetrics.sidebarWidth - MacLayoutMetrics.inspectorWidth)
    }

    @Test func theInspectorFitsExactlyAtItsThreshold() {
        let sidebar = MacLayoutMetrics.sidebarWidth
        let threshold = sidebar + MacLayoutMetrics.inspectorWidth + MacLayoutMetrics.chatColumnMin
        #expect(MacLayoutMetrics.inspectorFits(window: threshold, sidebar: sidebar))
        #expect(!MacLayoutMetrics.inspectorFits(window: threshold - 1, sidebar: sidebar))
        #expect(threshold == 1_100)
    }

    @Test func aWiderSidebarCollapsesTheInspectorSooner() {
        let wide = MacLayoutMetrics.sidebarWidthRange.upperBound
        #expect(!MacLayoutMetrics.inspectorFits(window: 1_100, sidebar: wide))
        #expect(MacLayoutMetrics.inspectorFits(window: 1_280, sidebar: wide))
    }

    @Test func aHiddenInspectorTakesNoWidthAndTheColumnsFillTheWindow() {
        for window in Self.windows {
            for sidebar in Self.sidebars {
                let allocation = MacLayoutMetrics.allocate(window: window, sidebar: sidebar, inspectorRequested: false)
                #expect(allocation.inspector == 0)
                #expect(allocation.sidebar + allocation.chat + allocation.inspector == window)
            }
        }
    }

    @Test func theCompactRailKeepsItsWidthToo() {
        let allocation = MacLayoutMetrics.allocate(window: 900, sidebar: MacLayoutMetrics.railWidth, inspectorRequested: true)
        #expect(allocation.sidebar == MacLayoutMetrics.railWidth)
        #expect(allocation.chatOriginX == MacLayoutMetrics.railWidth)
    }
}

@Suite("Leading bounded layout")
struct LeadingBoundedLayoutTests {
    @Test func aChildWiderThanItsColumnIsReportedAtTheColumnWidth() {
        #expect(LeadingBoundedLayout.boundedWidth(content: 460, limit: 258) == 258)
    }

    @Test func aNarrowerChildKeepsItsOwnWidth() {
        #expect(LeadingBoundedLayout.boundedWidth(content: 120, limit: 258) == 120)
    }

    @Test func noProposedWidthLeavesTheChildAlone() {
        #expect(LeadingBoundedLayout.boundedWidth(content: 460, limit: nil) == 460)
    }
}
