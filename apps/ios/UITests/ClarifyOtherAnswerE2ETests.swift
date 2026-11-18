import XCTest

@MainActor
final class ClarifyOtherAnswerE2ETests: E2ETestCase {
    @discardableResult
    private func focusOther(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["clarifyOtherField"]
        waitFor(field, timeout: 10, "Something else is an inline input in the card")
        XCTAssertEqual(field.placeholderValue, "Something else", "the input carries the placeholder")
        app.descendants(matching: .any)["clarifyOther"].hit()
        let focused = NSPredicate { element, _ in ((element as? XCUIElement)?.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        let focus = expectation(for: focused, evaluatedWith: field)
        wait(for: [focus], timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["clarifyOther"].isSelected, "focus shows the chosen treatment, not a system ring")
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
        focusOther(app)
        shot(app, "chat-clarify-other-field")
        app.typeText("mint\n")
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint").firstMatch, timeout: 60, "typed answer completes the turn")
        waitFor(bubbles(app, "clarifyAnswered", containing: "mint").firstMatch, timeout: 10, "typed answer shows on the answered card")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "mint").count, 0, "typed answer is not a new chat message")
    }

    func test2BlankIsNotSentAndTypedTextJoinsSelections() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFYMULTI other " + UUID().uuidString.prefix(4))
        app.buttons["clarifyChoice-0"].hit()
        focusOther(app)
        app.typeText("   \n")
        XCTAssertFalse(app.descendants(matching: .any)["clarifyAnswered"].waitForExistence(timeout: 3), "a blank answer is not sent")
        app.buttons["clarifyChoice-1"].hit()
        XCTAssertTrue(app.buttons["clarifyChoice-0"].isSelected, "earlier selection kept")
        XCTAssertTrue(app.buttons["clarifyChoice-1"].isSelected, "new selection made")
        focusOther(app).typeText("mint")
        XCTAssertTrue(app.descendants(matching: .any)["clarifyOther"].isSelected, "typing marks the row chosen")
        app.buttons["clarifyConfirm"].hit()
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint").firstMatch, timeout: 60, "multi-select typed answer completes the turn")
    }

    func test3BatchTakesTypedAnswerForEachQuestion() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFYBATCH other " + UUID().uuidString.prefix(4))
        focusOther(app)
        app.typeText("mint\n")
        waitFor(app.staticTexts["Which size?"], timeout: 60, "second question of the batch")
        focusOther(app)
        app.typeText("huge\n")
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, mint, huge").firstMatch, timeout: 60, "both typed answers reach the turn")
    }
}
