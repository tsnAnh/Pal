import XCTest

@MainActor
final class ClarifySettledE2ETests: E2ETestCase {
    private func ask(_ app: XCUIApplication, _ text: String, card: String) {
        send(app, text + " " + UUID().uuidString.prefix(4))
        waitFor(app.descendants(matching: .any)[card], timeout: 60, card)
    }

    func test1ASingleQuestionCollapsesToTheQuestionAndTheChosenRow() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFY settled", card: "clarifyCard")
        app.buttons["clarifyChoice-0"].hit()
        let settled = bubbles(app, "clarifyAnswered", containing: ": ").firstMatch
        waitFor(settled, timeout: 10, "the settled card")
        XCTAssertFalse(app.buttons["clarifyChoice-1"].exists, "no unchosen option stays")
        XCTAssertFalse(app.descendants(matching: .any)["clarifyOther"].exists, "no Something else row stays")
        XCTAssertFalse(app.buttons["clarifyConfirm"].exists, "no button stays")
        shot(app, "chat-clarify-settled")
    }

    func test2AFormCollapsesToOneBlockAfterTheLastAnswer() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        ask(app, "CLARIFYFLOW settled", card: "clarifyForm")
        app.buttons["clarifyChoice-0"].hit()
        waitFor(app.staticTexts["Which size?"], timeout: 5, "second question")
        app.buttons["clarifyChoice-0"].hit()
        app.buttons["clarifyChoice-1"].hit()
        app.buttons["clarifyConfirm"].hit()
        let field = app.textFields["clarifyOpenField"]
        waitFor(field, timeout: 5, "text field")
        field.hit()
        app.typeText("mint\n")
        waitFor(bubbles(app, "clarifyAnsweredForm", containing: "mint").firstMatch, timeout: 30, "one settled block")
        XCTAssertFalse(app.buttons["clarifyChoice-0"].exists, "no option stays")
        XCTAssertFalse(app.buttons["clarifyDot-0"].exists, "no page dots stay")
        shot(app, "chat-clarify-form-settled")
    }
}
