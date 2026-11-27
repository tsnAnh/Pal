import XCTest

@MainActor
final class PadTypeToFocusE2ETests: E2ETestCase {
    override func setUp() async throws {
        #if os(iOS)
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "hardware keyboard type to focus is iPad only")
        #else
        throw XCTSkip("hardware keyboard type to focus is iPad only")
        #endif
        try await super.setUp()
    }

    private func openChat() -> XCUIApplication {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        return app
    }

    private func composerText(_ app: XCUIApplication) -> String {
        let value = app.descendants(matching: .any)["composerField"].value as? String ?? ""
        return value.hasPrefix("Message") ? "" : value
    }

    private func waitForComposer(_ app: XCUIApplication, _ expected: String) {
        let matches = NSPredicate { _, _ in self.composerText(app) == expected }
        wait(for: [expectation(for: matches, evaluatedWith: nil)], timeout: 10)
        XCTAssertEqual(composerText(app), expected)
    }

    func test1TypingWithNothingFocusedFillsTheComposer() throws {
        let app = openChat()
        let before = composerText(app)
        for key in ["h", "e", "l", "l", "o"] { app.typeKey(key, modifierFlags: []) }
        waitForComposer(app, before + "hello")
        shot(app, "pad-type-to-focus")
    }

    func test2CommandArrowsAndEscapeLeaveTheComposerAlone() throws {
        let app = openChat()
        let before = composerText(app)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(composerText(app), before)
        app.typeKey("z", modifierFlags: [])
        waitForComposer(app, before + "z")
    }

    func test3AFocusedFieldKeepsItsKeys() throws {
        let app = openChat()
        app.buttons["chatMenuButton"].tap()
        waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
        app.buttons["chatMenuFind"].tap()
        let find = app.textFields["findField"]
        waitFor(find, timeout: 10, "find field")
        find.tap()
        app.typeKey("q", modifierFlags: [])
        let typed = NSPredicate { _, _ in (find.value as? String) == "q" }
        wait(for: [expectation(for: typed, evaluatedWith: nil)], timeout: 10)
        XCTAssertEqual(find.value as? String, "q")
    }
}
