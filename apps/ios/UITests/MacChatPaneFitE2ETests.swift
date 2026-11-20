#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacChatPaneFitE2ETests: BotProfileTestCase {
    private static let tolerance: CGFloat = 1
    private static let resizeAccuracy: CGFloat = 8
    private static let sidebarAccuracy: CGFloat = 6
    private static let headerCentreAccuracy: CGFloat = 24
    private static let windowWidth: CGFloat = MacLayoutMetrics.defaultWindowWidth
    private static let widestSidebar = MacLayoutMetrics.sidebarWidthRange.upperBound

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
        continueAfterFailure = true
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func ensureExpandedSidebar(_ app: XCUIApplication) {
        if any(app, "sidebarRail").exists {
            app.typeKey("b", modifierFlags: .command)
        }
        waitFor(any(app, "sidebarExpanded"), timeout: 10, "expanded sidebar")
    }

    private func resizeWindow(_ app: XCUIApplication, toWidth target: CGFloat) {
        let window = app.windows.firstMatch
        let delta = target - window.frame.width
        guard abs(delta) > Self.tolerance else { return }
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: delta, dy: 0)))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(window.frame.width - target) > Self.resizeAccuracy {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func widenSidebar(_ app: XCUIApplication, to target: CGFloat) {
        let sidebar = any(app, "sidebarExpanded")
        let delta = target - sidebar.frame.width
        guard abs(delta) > Self.tolerance else { return }
        let handle = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: sidebar.frame.maxX + 2, dy: sidebar.frame.midY))
        handle.press(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: delta, dy: 0)))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(sidebar.frame.width - target) > Self.sidebarAccuracy {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func assertInside(_ element: XCUIElement, _ pane: CGRect, _ name: String, _ moment: String) {
        XCTAssertTrue(element.exists, "\(moment): \(name) is on screen")
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minX, pane.minX - Self.tolerance, "\(moment): \(name) starts left of the chat pane")
        XCTAssertLessThanOrEqual(frame.maxX, pane.maxX + Self.tolerance, "\(moment): \(name) ends right of the chat pane, clipped by the window edge")
    }

    func test1TheChatPaneStaysInsideTheWindowAtTheWidestSidebar() throws {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        app.activate()
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch, timeout: 30, "roster rows")
        ensureExpandedSidebar(app)
        openBot(app, "cho-ua")
        let probe = "pane fit probe " + UUID().uuidString.prefix(6)
        send(app, probe)
        waitFor(bubbles(app, "userBubble", containing: probe).firstMatch, timeout: 15, "the sent message appears")

        resizeWindow(app, toWidth: Self.windowWidth)
        widenSidebar(app, to: Self.widestSidebar)
        let window = app.windows.firstMatch.frame
        let sidebar = any(app, "sidebarExpanded").frame
        let moment = "window \(Int(window.width)), sidebar \(Int(sidebar.width))"
        XCTAssertEqual(window.width, Self.windowWidth, accuracy: Self.resizeAccuracy, "\(moment): the window reached its default width")
        XCTAssertEqual(sidebar.width, Self.widestSidebar, accuracy: Self.sidebarAccuracy, "\(moment): the sidebar reached its widest width")

        let pane = any(app, "chatScreen").frame
        XCTAssertGreaterThanOrEqual(pane.minX, sidebar.maxX - Self.tolerance, "\(moment): the chat pane starts after the sidebar")
        XCTAssertLessThanOrEqual(pane.maxX, window.maxX + Self.tolerance, "\(moment): the chat pane ends inside the window")
        XCTAssertEqual(
            pane.width, window.width - sidebar.width, accuracy: Self.resizeAccuracy,
            "\(moment): the chat pane is the window minus the sidebar, not the whole window"
        )

        let title = any(app, "chatTitle")
        assertInside(title, pane, "the header pill", moment)
        XCTAssertEqual(title.frame.midX, pane.midX, accuracy: Self.headerCentreAccuracy, "\(moment): the header pill is centred in the chat pane")
        assertInside(any(app, "composerField"), pane, "the composer", moment)

        let onScreen: (XCUIElement) -> Bool = { $0.frame.width > 0 && $0.frame.intersects(pane) }
        let user = app.descendants(matching: .any).matching(identifier: "userBubble").allElementsBoundByIndex.filter(onScreen)
        XCTAssertFalse(user.isEmpty, "\(moment): a user bubble is on screen")
        for bubble in user {
            assertInside(bubble, pane, "a user bubble", moment)
        }
        let assistant = app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex.filter(onScreen)
        for bubble in assistant {
            assertInside(bubble, pane, "an assistant bubble", moment)
        }
        shot(app, "mac-chat-pane-fit")
    }
}
#endif
