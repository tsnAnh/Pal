import XCTest

@MainActor
final class VerticalScrollE2ETests: BotProfileTestCase {
    private static let swipes = 3

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] == "perf",
            "needs a gateway started with --seed perf and HERMES_UITEST_SEED=perf"
        )
        try await super.setUp()
    }

    private func onScreenMarkers(_ driver: PagingDriver) throws -> Set<String> {
        Set(try driver.settled().reading.onScreen.compactMap(\.marker))
    }

    func test1SwipingOnTheBubblesScrollsTheChatList() throws {
        let app = signedInApp()
        openBot(app, "bot-alpha")
        let driver = PagingDriver(app: app)
        _ = try driver.waitForContent(timeout: 60)
        let screen = element(app, "chatScreen")
        let opened = try onScreenMarkers(driver)
        for _ in 0..<Self.swipes { screen.swipeDown(velocity: .slow) }
        let older = try onScreenMarkers(driver)
        shot(app, "vertical-scroll-chat-older")
        XCTAssertNotEqual(older, opened, "a vertical swipe that starts on a bubble scrolls the chat list to older rows")
        for _ in 0..<Self.swipes { screen.swipeUp(velocity: .slow) }
        XCTAssertNotEqual(try onScreenMarkers(driver), older, "a vertical swipe back scrolls the chat list to newer rows")
    }

    func test2SwipingUpScrollsTheHomeList() throws {
        let app = signedInApp()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-"))
        let screen = element(app, "rosterScreen")
        let firstBefore = rows.firstMatch.identifier
        let frameBefore = rows.firstMatch.frame
        let allFit = rows.allElementsBoundByIndex.allSatisfy { screen.frame.contains($0.frame) }
        try XCTSkipIf(allFit, "every bot row fits on screen in this seed, so the Home list has nothing to scroll")
        screen.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        shot(app, "vertical-scroll-home")
        let moved = rows.firstMatch.identifier != firstBefore || rows.firstMatch.frame.minY < frameBefore.minY - 1
        XCTAssertTrue(moved, "a vertical swipe on the Home rows scrolls the list")
    }
}
