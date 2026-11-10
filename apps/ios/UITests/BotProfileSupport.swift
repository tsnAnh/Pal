import HermesDesign
import XCTest

@MainActor
class BotProfileTestCase: E2ETestCase {
    static let primarySlug = "default"
    static let otherSlug = "cho-ua"

    func signedInApp() -> XCUIApplication {
        let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue])
        signInIfNeeded(app)
        let anyBotRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch
        waitFor(anyBotRow, timeout: 30, "roster rows")
        return app
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func openProfile(_ app: XCUIApplication, _ slug: String) {
        let row = app.buttons["botRow-\(slug)"]
        waitFor(row, timeout: 30, "roster row \(slug)")
        #if os(macOS)
        row.rightClick()
        let viewProfile = app.menuItems["View Profile"]
        #else
        row.press(forDuration: 1.2)
        let viewProfile = app.buttons["View Profile"]
        #endif
        waitFor(viewProfile, timeout: 10, "context menu View Profile")
        viewProfile.hit()
        waitFor(element(app, "botProfileScreen"), timeout: 20, "profile screen")
        waitFor(element(app, "profileAvatar"), timeout: 20, "profile avatar")
    }

    func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        waitFor(back, timeout: 10, "back button")
        back.hit()
    }

    func waitUntil(_ timeout: TimeInterval = 20, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail(message, file: file, line: line)
    }

    func safariDone() -> XCUIElement {
        XCUIApplication().buttons["Close"]
    }

    func confirmReplace(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Replace")).firstMatch
        waitFor(confirm, timeout: 10, "replace confirmation")
        confirm.hit()
    }

    func toggleIsOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    func firstRoutineToggle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "routineToggle-"))
            .element(boundBy: 0)
    }
}
