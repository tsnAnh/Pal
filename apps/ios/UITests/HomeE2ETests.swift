import XCTest

@MainActor
final class HomeE2ETests: E2ETestCase {
    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["botRow-\(name)"]
    }

    private func openMenu(_ app: XCUIApplication, on name: String) {
        let target = row(app, name)
        waitFor(target, timeout: 30, "row \(name)")
        target.press(forDuration: 1.2)
    }

    func test1CreateBotOpensItsChat() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        waitFor(row(app, "cho-ua"), timeout: 30, "roster")
        app.buttons["createBotButton"].tap()
        waitFor(app.descendants(matching: .any)["createBotSheet"], timeout: 10, "create sheet")
        let confirm = app.buttons["createBotConfirm"]
        XCTAssertFalse(confirm.isEnabled, "Create stays disabled until the bot is named")
        shot(app, "create-bot-empty")
        app.buttons["botShape-spark"].tap()
        app.buttons["botSwatch-833cf8"].tap()
        let field = app.textFields["botNameField"]
        field.tap()
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard for the name field")
        field.typeText("Zed Scout")
        XCTAssertTrue(confirm.isEnabled)
        shot(app, "create-bot-filled")
        field.typeText("\n")
        confirm.tap()
        waitFor(app.descendants(matching: .any)["chatScreen"], timeout: 30, "the new bot's chat opens")
        shot(app, "create-bot-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(row(app, "zed-scout"), timeout: 30, "new bot is in the roster")
        XCTAssertTrue(row(app, "zed-scout").label.contains("Zed Scout"), row(app, "zed-scout").label)
    }

    func test2PinAndUnpinMovesTheBotToTheTopAvatars() throws {
        let app = launch()
        signInIfNeeded(app)
        let hero = app.descendants(matching: .any)["heroAvatar-cho-ua"]
        openMenu(app, on: "cho-ua")
        app.buttons["pinAction"].tap()
        waitFor(hero, timeout: 15, "pinned bot shows as a top avatar")
        shot(app, "pinned")
        row(app, "cho-ua").press(forDuration: 1.2)
        app.buttons["unpinAction"].tap()
        waitGone(hero, timeout: 15, "unpinned bot leaves the top avatars")
        XCTAssertTrue(row(app, "cho-ua").waitForExistence(timeout: 10))
    }

    func test3MakePrimaryMovesTheStar() throws {
        let app = launch()
        signInIfNeeded(app)
        let beta = row(app, "cho-dinh")
        waitFor(beta, timeout: 30, "row cho-dinh")
        XCTAssertFalse(beta.label.contains("primary bot"), beta.label)
        let previous = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "botRow-", "primary bot")).firstMatch
        waitFor(previous, timeout: 10, "an existing primary bot")
        let previousIdentifier = previous.identifier
        openMenu(app, on: "cho-dinh")
        app.buttons["makePrimaryAction"].tap()
        let promoted = NSPredicate(format: "label CONTAINS %@", "primary bot")
        expectation(for: promoted, evaluatedWith: beta)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons[previousIdentifier].label.contains("primary bot"), "the star moved")
        shot(app, "primary-moved")
        app.buttons[previousIdentifier].press(forDuration: 1.2)
        app.buttons["makePrimaryAction"].tap()
        expectation(for: promoted, evaluatedWith: app.buttons[previousIdentifier])
        waitForExpectations(timeout: 15)
    }

    func test4SearchFindsAMessageAndOpensItsChat() throws {
        let app = launch()
        signInIfNeeded(app)
        waitFor(app.buttons["rosterSearchField"], timeout: 30, "roster")
        app.buttons["rosterSearchField"].tap()
        waitFor(app.buttons["searchChips-messages"], timeout: 10, "chips")
        app.buttons["searchChips-messages"].tap()
        let field = app.descendants(matching: .any)["searchField"]
        waitFor(field, timeout: 10, "search field")
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard for the search field")
        field.typeText("Crashlytics")
        let hit = app.buttons["searchResult-message-cho-dinh"]
        waitFor(hit, timeout: 20, "message hit")
        XCTAssertTrue(hit.label.contains("Crashlytics"), hit.label)
        shot(app, "search-message")
        hit.tap()
        waitFor(app.descendants(matching: .any)["chatScreen"], timeout: 20, "hit opens the bot chat")
        XCTAssertFalse(app.descendants(matching: .any)["searchScreen"].exists)
    }

    func test5WorkingBotShowsItsActivity() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "market-researcher")
        send(app, "SLOW keep working")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let working = NSPredicate(format: "value == %@", "working")
        expectation(for: working, evaluatedWith: row(app, "market-researcher"))
        waitForExpectations(timeout: 20)
        shot(app, "working")
    }

    func test6ConnectAppsButtonOpensTheSheet() throws {
        let app = launch()
        signInIfNeeded(app)
        let button = app.buttons["connectAppsButton"]
        waitFor(button, timeout: 30, "connect apps button")
        button.tap()
        waitFor(app.descendants(matching: .any)["connectApps"], timeout: 20, "connect apps sheet")
        shot(app, "connect-apps-from-home")
    }
}
