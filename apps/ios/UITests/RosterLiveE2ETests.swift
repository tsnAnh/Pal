import XCTest

@MainActor
final class RosterLiveE2ETests: E2ETestCase {
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["botRow-\(name)"]
    }

    private func waitForValue(
        _ element: XCUIElement,
        _ expected: String,
        timeout: TimeInterval,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        let result = XCTWaiter().wait(for: [matches], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "\(message) expected value \(expected), got \(String(describing: element.value))\n" + XCUIApplication().debugDescription,
            file: file, line: line
        )
    }

    private func signedInRoster(resetCredentials: Bool = false) -> XCUIApplication {
        let app = launch(resetCredentials: resetCredentials)
        signInIfNeeded(app)
        waitFor(row(app, "bot-alpha"), timeout: 30, "alpha row")
        waitFor(row(app, "bot-beta"), timeout: 30, "beta row")
        return app
    }

    func test1ExternalTurnShowsWorkingThenIdleWithNewPreview() throws {
        let app = signedInRoster(resetCredentials: true)
        let alpha = row(app, "bot-alpha")
        waitForValue(alpha, "idle", timeout: 20, "alpha starts idle")
        let betaBefore = row(app, "bot-beta").value as? String
        shot(app, "realtime-1-idle")

        let started = Date()
        try control("external-slow-alpha")
        waitForValue(alpha, "working", timeout: 6, "external turn is visible without interaction")
        XCTContext.runActivity(named: "working appeared \(String(format: "%.1f", Date().timeIntervalSince(started))) s after submit") { _ in }
        shot(app, "realtime-2-working")
        XCTAssertEqual(row(app, "bot-beta").value as? String, betaBefore, "other bots are unaffected")

        waitForValue(alpha, "idle", timeout: 45, "turn finishes")
        XCTAssertTrue(alpha.label.contains("slow-"), "new reply preview landed: \(alpha.label)")
        shot(app, "realtime-3-idle-new-preview")
        try control("stop-external")
    }

    func test2GatewayLossShowsOfflineThenRecoversWithoutInteraction() throws {
        let app = signedInRoster()
        let dot = app.buttons["userAvatarButton"]
        waitForValue(row(app, "bot-alpha"), "idle", timeout: 30, "alpha idle before the outage")
        waitForValue(dot, "Connected", timeout: 10, "presence dot connected")
        shot(app, "realtime-4-connected")

        try control("kill-gateway")
        waitForValue(row(app, "bot-alpha"), "offline", timeout: 8, "alpha offline")
        waitForValue(row(app, "bot-beta"), "offline", timeout: 8, "beta offline")
        XCTAssertNotEqual(dot.value as? String, "Connected", "presence dot left connected")
        shot(app, "realtime-5-offline")

        try control("start-gateway")
        waitForValue(row(app, "bot-alpha"), "idle", timeout: 60, "alpha recovers")
        waitForValue(row(app, "bot-beta"), "idle", timeout: 10, "beta recovers")
        waitForValue(dot, "Connected", timeout: 10, "presence dot recovers")
        shot(app, "realtime-6-recovered")
    }

    func test3ExternalClarifyShowsNeedsInputInRosterAndChatHeader() throws {
        let app = signedInRoster()
        let alpha = row(app, "bot-alpha")
        waitForValue(alpha, "idle", timeout: 30, "alpha idle")

        try control("external-clarify-alpha")
        waitForValue(alpha, "needs-input", timeout: 8, "clarify surfaces as needs-input")
        shot(app, "realtime-7-needs-input")

        alpha.tap()
        let title = app.descendants(matching: .any)["chatTitle"]
        waitFor(title, timeout: 20, "chat header")
        waitForValue(title, "needs-input", timeout: 10, "chat header shares the activity")
        waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 30, "clarify card")
        shot(app, "realtime-8-chat-needs-input")

        try control("stop-external")
    }
}
