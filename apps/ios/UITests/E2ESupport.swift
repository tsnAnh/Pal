import XCTest

@MainActor
struct E2EEnvironment {
    let baseURL: String
    let username: String
    let password: String
    let controlDirectory: String?
    let shotsDirectory: String?

    static func load() throws -> E2EEnvironment {
        let env = ProcessInfo.processInfo.environment
        return E2EEnvironment(
            baseURL: try XCTUnwrap(env["HERMES_UITEST_BASE_URL"], "HERMES_UITEST_BASE_URL not set"),
            username: try XCTUnwrap(env["HERMES_UITEST_USERNAME"], "HERMES_UITEST_USERNAME not set"),
            password: try XCTUnwrap(env["HERMES_UITEST_PASSWORD"], "HERMES_UITEST_PASSWORD not set"),
            controlDirectory: env["HERMES_UITEST_CTL"],
            shotsDirectory: env["HERMES_UITEST_SHOTS"]
        )
    }
}

@MainActor
class E2ETestCase: XCTestCase {
    var env: E2EEnvironment!

    override func setUp() async throws {
        continueAfterFailure = false
        env = try E2EEnvironment.load()
    }

    func launch(resetCredentials: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (resetCredentials ? ["-hermes-reset-credentials"] : []) + extraArguments
        app.launch()
        return app
    }

    func signInIfNeeded(_ app: XCUIApplication) {
        if roster(app).waitForExistence(timeout: 15) { return }
        let field = app.textFields["baseURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != "https://your-host.tailnet.ts.net" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(env.baseURL)
        app.buttons["signInButton"].tap()

        let consent = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Continue"]
        if consent.waitForExistence(timeout: 5) { consent.tap() }

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20), app.debugDescription)
        let userField = web.textFields.firstMatch
        XCTAssertTrue(userField.waitForExistence(timeout: 20), app.debugDescription)
        userField.tap()
        userField.typeText(env.username)
        let passwordField = web.secureTextFields.firstMatch
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        passwordField.tap()
        passwordField.typeText(env.password)
        web.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign in")).firstMatch.tap()
        XCTAssertTrue(roster(app).waitForExistence(timeout: 40), app.debugDescription)
    }

    func roster(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["rosterScreen"]
    }

    func openBot(_ app: XCUIApplication, _ name: String) {
        let row = app.buttons["botRow-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chatScreen"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["composerField"].waitForExistence(timeout: 20), app.debugDescription)
    }

    func send(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["composerField"]
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()
    }

    func bubbles(_ app: XCUIApplication, _ identifier: String, containing text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 30, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message + "\n" + XCUIApplication().debugDescription, file: file, line: line)
    }

    func waitGone(_ element: XCUIElement, timeout: TimeInterval = 60, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message, file: file, line: line)
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = env.shotsDirectory {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    func control(_ command: String, timeout: TimeInterval = 120) throws {
        let directory = try XCTUnwrap(env.controlDirectory, "HERMES_UITEST_CTL not set")
        let request = URL(fileURLWithPath: directory).appendingPathComponent("request")
        let ack = URL(fileURLWithPath: directory).appendingPathComponent("ack")
        try? FileManager.default.removeItem(at: ack)
        try command.write(to: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: ack.path) {
            XCTAssertLessThan(Date(), deadline, "control command \(command) was not acknowledged")
            Thread.sleep(forTimeInterval: 0.25)
        }
        let result = (try? String(contentsOf: ack, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(result, "ok", "control command \(command) failed")
    }
}
