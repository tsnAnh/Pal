import PalDesign
import XCTest

@MainActor
final class ChatListNoShiftE2ETests: E2ETestCase {
    private static let tolerance: CGFloat = 1

    private func requireParitySeed() throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertListIsAtItsMargins(_ app: XCUIApplication, _ moment: String) {
        let screen = any(app, "chatScreen")
        let width = screen.frame.width
        XCTAssertEqual(screen.frame.minX, 0, accuracy: Self.tolerance, "\(moment): the chat screen itself does not move")
        let assistant = app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex
            .filter { $0.frame.width > 0 && $0.frame.intersects(screen.frame) }
        XCTAssertFalse(assistant.isEmpty, "\(moment): an assistant bubble is on screen")
        for bubble in assistant {
            XCTAssertEqual(
                bubble.frame.minX, ChatMetrics.edgeMargin, accuracy: Self.tolerance,
                "\(moment): an assistant bubble sits at the leading margin, not shifted left"
            )
        }
        let table = any(app, "markdownTable")
        if table.exists {
            XCTAssertGreaterThanOrEqual(table.frame.minX, ChatMetrics.edgeMargin - Self.tolerance, "\(moment): the table starts at the margin")
            XCTAssertLessThanOrEqual(
                table.frame.maxX, width - ChatMetrics.edgeMargin + Self.tolerance,
                "\(moment): the table stays inside the list; it scrolls in its own scroll view"
            )
        }
        for bubble in app.descendants(matching: .any).matching(identifier: "userBubble").allElementsBoundByIndex where bubble.frame.intersects(screen.frame) {
            XCTAssertEqual(
                bubble.frame.maxX, width - ChatMetrics.edgeMargin, accuracy: Self.tolerance,
                "\(moment): a user bubble sits at the trailing margin"
            )
        }
    }

    func test1OpeningAChatWithAWideTableAndCodeKeepsTheListAtItsMargins() throws {
        try requireParitySeed()
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, "cho-dinh")
        waitFor(any(app, "markdownTable"), timeout: 30, "the seeded wide table")
        waitFor(any(app, "codeBlock"), timeout: 30, "the seeded code block")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "list-no-shift-opened")
        assertListIsAtItsMargins(app, "after open")
    }

    func test2SendingAMessageKeepsTheListAtItsMargins() throws {
        try requireParitySeed()
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, "cho-dinh")
        waitFor(any(app, "markdownTable"), timeout: 30, "the seeded wide table")
        let probe = "list shift probe " + UUID().uuidString.prefix(6)
        send(app, probe)
        waitFor(bubbles(app, "userBubble", containing: probe).firstMatch, timeout: 15, "the sent message appears")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "list-no-shift-after-send")
        assertListIsAtItsMargins(app, "after send")
    }

    func test3AToolTurnAfterAWrappedDraftKeepsTheListAtItsMargins() throws {
        let app = launch(extraArguments: ["-hermes-reset-preferences"])
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "SLOW a longer draft that wraps onto a second line so the composer grows " + UUID().uuidString.prefix(4))
        waitFor(any(app, "assistantBubble-streaming"), timeout: 30, "the slow reply starts")
        waitGone(any(app, "assistantBubble-streaming"), timeout: 90, "the slow reply completes")
        send(app, "TOOLCALL margin " + UUID().uuidString.prefix(4))
        waitFor(any(app, "workingStatus"), timeout: 60, "the tool status row")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "list-no-shift-tool-running")
        assertListIsAtItsMargins(app, "while a tool runs")
        waitGone(any(app, "assistantBubble-streaming"), timeout: 90, "the tool turn completes")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "list-no-shift-tool-done")
        assertListIsAtItsMargins(app, "after the tool turn")
    }
}
