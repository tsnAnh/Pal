#if os(iOS)
import XCTest

@MainActor
final class MessageMenuSheetE2ETests: E2ETestCase {
    func test1HoldOpensTheSheetAndAnActionClosesIt() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "hold this message")
        let bubble = bubbles(app, "userBubble", containing: "hold this message").firstMatch
        waitFor(bubble, timeout: 10, "user bubble")
        let menu = app.descendants(matching: .any)["messageContextMenu"]
        XCTAssertFalse(menu.exists, "no menu before the press")

        bubble.press(forDuration: 2)

        waitFor(menu, timeout: 5, "sheet after holding the bubble")
        waitFor(app.buttons["contextReaction-👍"], timeout: 5, "reactions in the sheet")
        waitFor(app.buttons["contextCopy"], timeout: 5, "copy in the sheet")
        waitFor(app.buttons["contextReply"], timeout: 5, "reply in the sheet")
        shot(app, "message-sheet")
        app.buttons["contextCopy"].hit()
        waitGone(menu, timeout: 10, "sheet closes after an action")
    }

    func test2SwipingTheBubbleVerticallyScrollsInsteadOfOpeningTheSheet() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "scroll past me")
        let bubble = bubbles(app, "userBubble", containing: "scroll past me").firstMatch
        waitFor(bubble, timeout: 10, "user bubble")
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 160))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertFalse(app.descendants(matching: .any)["messageContextMenu"].waitForExistence(timeout: 2), "a vertical drag never opens the sheet")
    }

    func test3SwipingTheBubbleRightStillRepliesWithoutOpeningTheSheet() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "reply to me")
        let bubble = bubbles(app, "userBubble", containing: "reply to me").firstMatch
        waitFor(bubble, timeout: 10, "user bubble")
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 160, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        waitFor(element(app, "replyBar"), timeout: 5, "reply bar after swiping the bubble")
        XCTAssertFalse(element(app, "messageContextMenu").exists, "a swipe never opens the sheet")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
#endif
