import XCTest

@MainActor
final class ActivationCardE2ETests: E2ETestCase {
    private static let server = "fixture-tools"
    private static let owner = "bot-alpha"
    private static let bystander = "bot-beta"
    private static let prompt = "ENABLE_FIXTURE_MCP"

    override func setUp() async throws {
        #if os(macOS)
        throw XCTSkip("drives the iOS simulator")
        #endif
        try await super.setUp()
    }

    func test1DenyLeavesServerDisabled() throws {
        let app = openOwnerChat()
        XCTAssertEqual(try fixtureEnabled(Self.owner), false, "the fixture starts disabled")

        send(app, Self.prompt)
        waitForCard(app, value: "open")
        shot(app, "activation-card-open")
        XCTAssertEqual(try fixtureEnabled(Self.owner), false, "an unanswered card enables nothing")

        newestCard(app).buttons["connectionDeny-\(Self.server)"].hit()
        waitForValue(state(app), "skipped", "denied target state")
        waitForCard(app, value: "settled")
        shot(app, "activation-card-denied")

        waitFor(bubbles(app, "assistantBubble", containing: "\(Self.server)=skipped").firstMatch, timeout: 60, "assistant names the skipped state")
        XCTAssertEqual(try fixtureEnabled(Self.owner), false, "deny leaves the server disabled")
        XCTAssertNil(try fixtureEnabled(Self.bystander), "the other bot is untouched")
        XCTAssertFalse(try profileLog(Self.owner).contains("fixture_echo"), "a denied server is never started")
    }

    func test2AllowEnablesAndDiscovers() throws {
        let app = openOwnerChat()
        XCTAssertEqual(try fixtureEnabled(Self.owner), false, "the fixture starts disabled")

        send(app, Self.prompt)
        waitForCard(app, value: "open")
        newestCard(app).buttons["connectionAllow-\(Self.server)"].hit()
        waitForValue(state(app), "connected", "allowed target state", timeout: 60)
        waitForCard(app, value: "settled")
        shot(app, "activation-card-connected")

        waitFor(bubbles(app, "assistantBubble", containing: "\(Self.server)=connected").firstMatch, timeout: 60, "assistant names the connected state")
        XCTAssertEqual(try fixtureEnabled(Self.owner), true, "allow enables the server for the asking bot")
        XCTAssertNil(try fixtureEnabled(Self.bystander), "the other bot is untouched")
        XCTAssertTrue(try profileLog(Self.owner).contains("fixture_echo"), "the gateway discovered the server's tool")
    }

    func test3ReopenRestoresOneCard() throws {
        let app = openOwnerChat()

        send(app, Self.prompt)
        waitForCard(app, value: "open")
        assertOneCard(app, value: "open", "before leaving")

        reopenOwnerChat(app)
        waitForCard(app, value: "open")
        assertOneCard(app, value: "open", "after reopening an open operation")

        newestCard(app).buttons["connectionDeny-\(Self.server)"].hit()
        waitForValue(state(app), "skipped", "denied target state")
        waitForCard(app, value: "settled")

        reopenOwnerChat(app)
        waitForCard(app, value: "settled")
        waitForValue(state(app), "skipped", "settled state restored")
        assertOneCard(app, value: "settled", "after reopening a settled operation")
        shot(app, "activation-card-reopened")

        try control("kill-gateway")
        waitFor(app.descendants(matching: .any)["reconnectingIndicator"], timeout: 30, "reconnecting indicator")
        try control("start-gateway")
        waitGone(app.descendants(matching: .any)["reconnectingIndicator"], timeout: 90, "reconnected after the gateway restart")
        waitForCard(app, value: "settled")
        waitForValue(state(app), "skipped", "settled state after the gateway restart")
        assertOneCard(app, value: "settled", "after the gateway restart")
        XCTAssertEqual(try fixtureEnabled(Self.owner), false, "the server stays disabled across the restart")
    }

    private func openOwnerChat() -> XCUIApplication {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, Self.owner)
        return app
    }

    private func reopenOwnerChat(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).hit()
        waitFor(app.buttons["botRow-\(Self.owner)"], timeout: 20, "roster after leaving the chat")
        openBot(app, Self.owner)
    }

    private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "connectionCard")
    }

    private func newestCard(_ app: XCUIApplication) -> XCUIElement {
        let query = cards(app)
        return query.element(boundBy: max(query.count - 1, 0))
    }

    private func state(_ app: XCUIApplication) -> XCUIElement {
        newestCard(app).descendants(matching: .any)["connectionState-\(Self.server)"]
    }

    private func waitForCard(_ app: XCUIApplication, value: String, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let card = newestCard(app)
            if card.exists, card.value as? String == value { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        shot(app, "activation-card-missing")
        XCTFail("connection card (\(value)) never appeared as the newest card\n" + app.debugDescription)
    }

    private func assertOneCard(_ app: XCUIApplication, value: String, _ when: String) {
        XCTAssertEqual(cards(app).count, 1, "exactly one connection card \(when)\n" + app.debugDescription)
        XCTAssertEqual(cards(app).firstMatch.value as? String, value, "the card is \(value) \(when)")
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, _ message: String, timeout: TimeInterval = 30) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: timeout), .completed, "\(message): expected \(value), saw \(String(describing: element.value))")
    }

    private func sandboxFile(_ components: String...) throws -> URL {
        let home = try XCTUnwrap(env.sandboxHome, "HERMES_UITEST_HOME not set; run through scripts/drive or scripts/drive-control")
        return components.reduce(URL(fileURLWithPath: home)) { $0.appendingPathComponent($1) }
    }

    private func profileLog(_ profile: String) throws -> String {
        try String(contentsOf: sandboxFile("profiles", profile, "logs", "agent.log"), encoding: .utf8)
    }

    private func fixtureEnabled(_ profile: String) throws -> Bool? {
        let config = try String(contentsOf: sandboxFile("profiles", profile, "config.yaml"), encoding: .utf8)
        var inServer = false
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "\(Self.server):" {
                inServer = true
            } else if inServer, indent <= 2, !text.isEmpty {
                return nil
            } else if inServer, text.hasPrefix("enabled:") {
                return text.dropFirst("enabled:".count).trimmingCharacters(in: .whitespaces) == "true"
            }
        }
        return nil
    }
}
