import XCTest

@MainActor
final class ClarifyFormFlowE2ETests: E2ETestCase {
    private func askFlow(_ app: XCUIApplication) {
        send(app, "CLARIFYFLOW " + UUID().uuidString.prefix(4))
        waitFor(app.descendants(matching: .any)["clarifyForm"], timeout: 60, "clarify form")
    }

    func test1SingleAdvancesByItselfAndNoNextButtonExists() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        askFlow(app)
        XCTAssertFalse(app.buttons["clarifyNext"].exists, "no Next button on a single-choice page")
        XCTAssertFalse(app.buttons["clarifyConfirm"].exists, "no confirm on a single-choice page")
        app.buttons["clarifyChoice-1"].hit()
        waitFor(app.staticTexts["Which size?"], timeout: 5, "single pick moves to the next question by itself")
        XCTAssertTrue(app.buttons["clarifyConfirm"].exists, "the multi-select page keeps one Done capsule")
        XCTAssertFalse(app.buttons["clarifyConfirm"].isEnabled, "Done waits for a pick")
    }

    func test2MultiThenTextAndTheLastAnswerSubmitsOnce() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        askFlow(app)
        app.buttons["clarifyChoice-0"].hit()
        waitFor(app.staticTexts["Which size?"], timeout: 5, "second question")
        app.buttons["clarifyChoice-0"].hit()
        app.buttons["clarifyChoice-1"].hit()
        app.buttons["clarifyConfirm"].hit()
        waitFor(app.staticTexts["Anything else to add?"], timeout: 5, "text question")
        let field = app.textFields["clarifyOpenField"]
        waitFor(field, timeout: 5, "text field")
        field.hit()
        app.typeText("mint\n")
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, vanilla").firstMatch, timeout: 60, "last answer submits the form")
        XCTAssertEqual(bubbles(app, "clarifyAnswered", containing: "mint").count, 1, "the form was sent once")
    }

    func test3BackAndDotsChangeAnEarlierAnswer() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        askFlow(app)
        app.buttons["clarifyChoice-0"].hit()
        waitFor(app.staticTexts["Which size?"], timeout: 5, "second question")
        app.buttons["clarifyBack"].hit()
        waitFor(app.staticTexts["Which flavor do you want?"], timeout: 5, "back to the first question")
        XCTAssertTrue(app.buttons["clarifyChoice-0"].isSelected, "the earlier pick is shown")
        app.buttons["clarifyChoice-1"].hit()
        waitFor(app.staticTexts["Which size?"], timeout: 5, "picking again advances")
        app.buttons["clarifyDot-0"].hit()
        waitFor(app.staticTexts["Which flavor do you want?"], timeout: 5, "a dot jumps to an answered page")
        XCTAssertTrue(app.buttons["clarifyChoice-1"].isSelected, "the changed pick is kept")
    }
}
