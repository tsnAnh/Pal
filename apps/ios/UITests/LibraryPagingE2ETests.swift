import XCTest

@MainActor
final class LibraryPagingE2ETests: BotProfileTestCase {
    private static let backlogSlug = "bot-alpha"
    private static let pageSize = 50
    private static let rowHeight: CGFloat = 65
    private static let cardInset: CGFloat = 12
    private static let maxSwipes = 80
    private static let settleSeconds: TimeInterval = 6
    private static let settleBudget: TimeInterval = 120

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"]
        try XCTSkipUnless(seed == "perf", "needs a gateway started with --seed perf and HERMES_UITEST_SEED=perf")
        try await super.setUp()
    }

    func test1LibraryLoadsOnePageAndFetchesMoreOnlyAtTheEnd() throws {
        let app = signedInApp()
        openProfile(app, Self.backlogSlug)
        element(app, "profileLibraryRow").tap()
        waitFor(element(app, "libraryScreen"), timeout: 20, "library screen")
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryCard-"))
        waitFor(cards.firstMatch, timeout: 30, "first section")
        settleLoadedRows(cards)
        XCTAssertEqual(loadedRows(cards), Self.pageSize, "opening the library loads one page and nothing more until the owner scrolls")
        shot(app, "library-paging-0-opened")
        let screen = element(app, "libraryScreen")
        var swipes = 0
        while loadedRows(cards) <= 2 * Self.pageSize, swipes < Self.maxSwipes {
            screen.swipeUp(velocity: .fast)
            swipes += 1
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThan(loadedRows(cards), 2 * Self.pageSize, "scrolling to the end loaded the third page")
        shot(app, "library-paging-1-scrolled")
    }

    private func loadedRows(_ cards: XCUIElementQuery) -> Int {
        let sections = cards.allElementsBoundByIndex
        let height = sections.reduce(CGFloat(0)) { $0 + $1.frame.height - Self.cardInset }
        return Int((height / Self.rowHeight).rounded())
    }

    private func settleLoadedRows(_ cards: XCUIElementQuery) {
        var previous = -1
        let deadline = Date().addingTimeInterval(Self.settleBudget)
        while Date() < deadline {
            let current = loadedRows(cards)
            if current == previous { return }
            previous = current
            Thread.sleep(forTimeInterval: Self.settleSeconds)
        }
        XCTFail("the loaded library rows never settled")
    }
}
