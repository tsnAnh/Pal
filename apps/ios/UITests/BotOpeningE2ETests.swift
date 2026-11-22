import XCTest

@MainActor
final class BotOpeningE2ETests: E2ETestCase {
    private static let greeting = "You haven't given me a job yet, so let's figure out where I'd help you most."
    private static let choices = ["Everyday personal assistant", "Help with my apps and work", "A specific new job"]

    func test1ANewBotGreetsAndAsksWhatItIsFor() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        waitFor(app.buttons["botRow-bot-alpha"], timeout: 30, "roster")
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let name = "Hu \(suffix)"
        app.buttons["createBotButton"].tap()
        waitFor(app.descendants(matching: .any)["createBotSheet"], timeout: 10, "create sheet")
        let field = app.textFields["botNameField"]
        field.tap()
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard for the name field")
        field.typeText(name)
        field.typeText("\n")
        app.buttons["createBotConfirm"].tap()
        waitFor(app.descendants(matching: .any)["chatScreen"], timeout: 30, "the new bot's chat opens")

        waitFor(bubbles(app, "assistantBubble", containing: "I'm \(name). \(Self.greeting)").firstMatch, timeout: 90, "scripted greeting")
        waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 30, "job question card")
        XCTAssertTrue(app.staticTexts["What do you want me for?"].exists, "card asks what the bot is for")
        for (index, choice) in Self.choices.enumerated() {
            let button = app.buttons["clarifyChoice-\(index)"]
            waitFor(button, timeout: 10, "choice \(index)")
            XCTAssertTrue(button.label.contains(choice), button.label)
            XCTAssertFalse(button.label.contains("Recommended"), button.label)
        }
        XCTAssertFalse(app.buttons["clarifyChoice-3"].exists, "only three scripted choices before Something else")
        shot(app, "bot-opening-card")

        app.buttons["clarifyChoice-0"].tap()
        waitFor(bubbles(app, "clarifyAnswered", containing: Self.choices[0]).firstMatch, timeout: 30, "answer locks the card")
        shot(app, "bot-opening-answered")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let slug = "hu-\(suffix)"
        let row = app.buttons["botRow-\(slug)"]
        waitFor(row, timeout: 30, "new bot in the roster")
        XCTAssertNotEqual(row.value as? String, "attention", "a new bot never shows setup incomplete")
        shot(app, "bot-opening-roster")
    }
}
