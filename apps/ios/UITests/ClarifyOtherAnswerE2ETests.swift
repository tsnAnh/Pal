import XCTest

@MainActor
final class ClarifyOtherAnswerE2ETests: E2ETestCase {
    @discardableResult
    private func openOther(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["clarifyOther"].hit()
        let field = app.textFields["clarifyOtherField"]
        waitFor(field, timeout: 10, "Something else opens a field in the card")
        let focused = NSPredicate { element, _ in ((element as? XCUIElement)?.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        let focus = expectation(for: focused, evaluatedWith: field)
        wait(for: [focus], timeout: 5)
        return field
    }

    private func ask(_ app: XCUIApplication, _ text: String) {
        send(app, text)
        waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 60, "clarify card")
    }

    func test1SingleSelectReturnSubmitsTypedAnswer() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFY other " + UUID().uuidString.prefix(4))
        openOther(app)
        shot(app, "chat-clarify-other-field")
        app.typeText("mint\n")
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint").firstMatch, timeout: 60, "typed answer completes the turn")
        waitFor(bubbles(app, "clarifyAnswered", containing: "mint").firstMatch, timeout: 10, "typed answer shows on the answered card")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "mint").count, 0, "typed answer is not a new chat message")
    }

    func test2BlankIsNotSentAndOptionsCloseTheField() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFYMULTI other " + UUID().uuidString.prefix(4))
        app.buttons["clarifyChoice-0"].hit()
        openOther(app)
        XCTAssertFalse(app.buttons["clarifyOtherSend"].isEnabled, "Send is off while the field is blank")
        app.typeText("   \n")
        XCTAssertFalse(app.descendants(matching: .any)["clarifyAnswered"].waitForExistence(timeout: 3), "a blank answer is not sent")
        app.buttons["clarifyChoice-1"].hit()
        waitGone(app.textFields["clarifyOtherField"], timeout: 5, "choosing an option closes the field")
        XCTAssertTrue(app.buttons["clarifyChoice-0"].isSelected, "earlier selection kept")
        XCTAssertTrue(app.buttons["clarifyChoice-1"].isSelected, "new selection made")
        openOther(app)
        app.buttons["clarifyOtherCancel"].hit()
        waitGone(app.textFields["clarifyOtherField"], timeout: 5, "Cancel closes the field")
        XCTAssertTrue(app.buttons["clarifyChoice-0"].isSelected && app.buttons["clarifyChoice-1"].isSelected, "Cancel keeps the selections")
        openOther(app).typeText("mint")
        app.buttons["clarifyOtherSend"].hit()
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint").firstMatch, timeout: 60, "multi-select typed answer completes the turn")
    }

    func test3BatchTakesTypedAnswerForEachQuestion() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFYBATCH other " + UUID().uuidString.prefix(4))
        openOther(app)
        app.typeText("mint\n")
        waitFor(app.staticTexts["Which size?"], timeout: 60, "second question of the batch")
        openOther(app).typeText("huge")
        app.buttons["clarifyOtherSend"].hit()
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint, huge").firstMatch, timeout: 60, "both typed answers reach the turn")
    }
}
