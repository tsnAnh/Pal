#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacSidebarFitE2ETests: BotProfileTestCase {
    private static let widths: [CGFloat] = [1280, 1100, 1000, 900]
    private static let tolerance: CGFloat = 1
    private static let columnTolerance: CGFloat = 6
    private static let resizeAccuracy: CGFloat = 8
    private static let maxLeadingInset: CGFloat = 24
    private static let minimumRows = 3

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

    private func visibleListRows(_ app: XCUIApplication, in sidebar: CGRect) -> [XCUIElement] {
        let hero = any(app, "pinnedHero")
        let heroFrame = hero.exists ? hero.frame : .zero
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
            .filter { !$0.frame.intersects(heroFrame) && $0.frame.midY >= sidebar.minY && $0.frame.midY <= sidebar.maxY }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func assertSidebarFits(_ app: XCUIApplication, window: CGRect, _ moment: String) {
        let sidebar = any(app, "sidebarExpanded")
        XCTAssertTrue(sidebar.exists, "\(moment): the expanded sidebar is on screen")
        let bounds = sidebar.frame
        XCTAssertGreaterThanOrEqual(bounds.minX, 0, "\(moment): the sidebar does not start left of the screen")
        XCTAssertGreaterThanOrEqual(bounds.minX, window.minX - Self.tolerance, "\(moment): the sidebar does not start left of the window")
        XCTAssertLessThanOrEqual(
            bounds.width, MacLayoutMetrics.sidebarWidthRange.upperBound + Self.tolerance,
            "\(moment): the sidebar stays within its width range"
        )

        let rows = visibleListRows(app, in: bounds)
        XCTAssertGreaterThanOrEqual(rows.count, Self.minimumRows, "\(moment): the seeded roster shows several list rows")

        var avatarsChecked = 0
        for row in rows {
            let name = String(row.identifier.dropFirst("botRow-".count))
            let frame = row.frame
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - Self.tolerance, "\(moment): row \(name) starts left of the sidebar, cropped")
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + Self.tolerance, "\(moment): row \(name) ends right of the sidebar")
            XCTAssertLessThanOrEqual(frame.width, bounds.width + Self.tolerance, "\(moment): row \(name) is wider than the sidebar")
            XCTAssertLessThanOrEqual(frame.minX - bounds.minX, Self.maxLeadingInset, "\(moment): row \(name) is pushed away from the sidebar's leading edge")
            if let first = rows.first {
                XCTAssertEqual(frame.minX, first.frame.minX, accuracy: Self.tolerance, "\(moment): row \(name) lines up with the other rows")
                XCTAssertEqual(frame.width, first.frame.width, accuracy: Self.tolerance, "\(moment): row \(name) is as wide as the other rows")
            }

            let avatar = app.descendants(matching: .any).matching(identifier: "rowAvatar-\(name)").firstMatch
            guard avatar.exists else { continue }
            avatarsChecked += 1
            XCTAssertGreaterThanOrEqual(avatar.frame.minX, frame.minX - Self.tolerance, "\(moment): avatar of \(name) starts left of its row")
            XCTAssertLessThanOrEqual(avatar.frame.maxX, frame.maxX + Self.tolerance, "\(moment): avatar of \(name) ends right of its row")
            XCTAssertGreaterThanOrEqual(avatar.frame.minX, bounds.minX - Self.tolerance, "\(moment): avatar of \(name) left of the sidebar")
            XCTAssertLessThanOrEqual(avatar.frame.maxX, bounds.maxX + Self.tolerance, "\(moment): avatar of \(name) right of the sidebar")
        }
        if avatarsChecked == 0 {
            XCTContext.runActivity(named: "\(moment): rowAvatar-* is not exposed inside a botRow, avatar frames not asserted") { _ in }
        }
    }

    private func assertChatColumnFits(_ app: XCUIApplication, sidebar: CGRect, _ moment: String) {
        let screen = any(app, "chatScreen").frame
        XCTAssertGreaterThanOrEqual(screen.minX, sidebar.maxX - Self.tolerance, "\(moment): the chat pane starts after the sidebar")
        let edge = ChatMetrics.edgeMargin
        let column = min(screen.width, MacLayoutMetrics.chatColumnMax + 2 * edge)
        let columnMinX = screen.minX + (screen.width - column) / 2

        let onScreen: (XCUIElement) -> Bool = { $0.frame.width > 0 && $0.frame.intersects(screen) }
        let assistant = app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex.filter(onScreen)
        XCTAssertFalse(assistant.isEmpty, "\(moment): an assistant bubble is on screen")
        for bubble in assistant {
            XCTAssertEqual(
                bubble.frame.minX, columnMinX + edge, accuracy: Self.columnTolerance,
                "\(moment): an assistant bubble sits at the leading margin of the chat column"
            )
        }
        let user = app.descendants(matching: .any).matching(identifier: "userBubble").allElementsBoundByIndex.filter(onScreen)
        XCTAssertFalse(user.isEmpty, "\(moment): a user bubble is on screen")
        for bubble in user {
            XCTAssertEqual(
                bubble.frame.maxX, columnMinX + column - edge, accuracy: Self.columnTolerance,
                "\(moment): a user bubble sits at the trailing margin of the chat column"
            )
        }
    }

    func test1SidebarRowsAndChatBubblesStayInsideTheirColumnsAtEveryWindowWidth() throws {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        app.activate()
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch, timeout: 30, "roster rows")
        ensureExpandedSidebar(app)
        openBot(app, "cho-ua")
        let probe = "sidebar fit probe " + UUID().uuidString.prefix(6)
        send(app, probe)
        waitFor(bubbles(app, "userBubble", containing: probe).firstMatch, timeout: 15, "the sent message appears")

        for target in Self.widths {
            let moment = "window \(Int(target))"
            resizeWindow(app, toWidth: target)
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(window.width, target, accuracy: Self.resizeAccuracy, "\(moment): the window reached the requested width")
            assertSidebarFits(app, window: window, moment)
            assertChatColumnFits(app, sidebar: any(app, "sidebarExpanded").frame, moment)
            shot(app, "mac-sidebar-fit-\(Int(target))")
        }
    }
}
#endif
