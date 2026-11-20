import PalDesign
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
    private static let outageSeconds: TimeInterval = 90
    private static let recoverBudget: TimeInterval = 90

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

    func test2AFailedNextPageShowsTryAgainAndRecovers() throws {
        for appearance in [AppearanceMode.dark, .light] {
            let app = signedInApp(appearance: appearance)
            openProfile(app, Self.backlogSlug)
            element(app, "profileLibraryRow").tap()
            waitFor(element(app, "libraryScreen"), timeout: 20, "library screen")
            let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryCard-"))
            waitFor(cards.firstMatch, timeout: 30, "first section")
            settleLoadedRows(cards)
            XCTAssertEqual(loadedRows(cards), Self.pageSize, "the first page loaded before the gateway went away")

            try control("kill-gateway")
            let footer = element(app, "libraryLoadMoreFailed")
            let screen = element(app, "libraryScreen")
            var swipes = 0
            while !footer.exists, swipes < Self.maxSwipes {
                screen.swipeUp(velocity: .fast)
                swipes += 1
                Thread.sleep(forTimeInterval: 0.5)
            }
            waitFor(footer, timeout: Self.outageSeconds, "the footer after the next page failed (\(appearance.rawValue))")
            let retry = app.buttons["libraryLoadMoreRetry"]
            while !retry.isHittable, swipes < Self.maxSwipes {
                screen.swipeUp(velocity: .slow)
                swipes += 1
            }
            XCTAssertTrue(retry.isHittable, "the footer offers Try again on screen")
            XCTAssertEqual(loadedRows(cards), Self.pageSize, "a failed page adds no rows")
            Thread.sleep(forTimeInterval: Self.settleSeconds)
            XCTAssertTrue(footer.exists, "nothing retried on its own while the footer was showing")
            shot(app, "library-load-more-failed-\(appearance.rawValue)-footer")

            try control("start-gateway")
            let deadline = Date().addingTimeInterval(Self.recoverBudget)
            while loadedRows(cards) <= Self.pageSize, Date() < deadline {
                if retry.exists, retry.isHittable { retry.tap() }
                Thread.sleep(forTimeInterval: 1)
            }
            XCTAssertGreaterThan(loadedRows(cards), Self.pageSize, "Try again loaded the next page once the gateway was back (\(appearance.rawValue))")
            XCTAssertFalse(footer.exists, "the footer went away once the page loaded")
            shot(app, "library-load-more-failed-\(appearance.rawValue)-recovered")
        }
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
