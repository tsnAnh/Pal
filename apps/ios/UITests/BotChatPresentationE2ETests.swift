import XCTest

@MainActor
final class BotChatPresentationE2ETests: E2ETestCase {
    func test1ToolRunShowsThinkingAndNoToolRow() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        send(app, "TOOLCALL run something")
        let thinking = app.descendants(matching: .any).matching(identifier: "assistantBubble-streaming")
            .matching(NSPredicate(format: "label == %@", "Thinking"))
        waitFor(thinking.firstMatch, timeout: 60, "thinking bubble")
        shot(app, "chat-tool-thinking")

        var thinkingSamples = 0
        let deadline = Date().addingTimeInterval(90)
        var finished = false
        while Date() < deadline, !finished {
            XCTAssertEqual(toolRows(app).count, 0, "tool rows stay hidden\n" + app.debugDescription)
            if thinking.firstMatch.exists { thinkingSamples += 1 }
            finished = bubbles(app, "assistantBubble", containing: "stub-tool-final").firstMatch.exists
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(finished, "turn completed")
        XCTAssertGreaterThanOrEqual(thinkingSamples, 3, "thinking bubble stays visible while the tool runs")
        waitGone(thinking.firstMatch, timeout: 15, "thinking bubble gone once the run ends")
        XCTAssertEqual(toolRows(app).count, 0)
        shot(app, "chat-tool-finished")
    }

    func test2ApprovalCardUsesProductLanguage() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        send(app, "APPROVE this")
        let allow = app.buttons["approvalChoice-0"]
        waitFor(allow, timeout: 60, "approval card")
        XCTAssertEqual(allow.label, "Allow")
        let decline = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "approvalChoice-", "Don't allow")).firstMatch
        XCTAssertTrue(decline.exists, "Don't allow button\n" + app.debugDescription)
        for raw in ["once", "session", "always", "deny"] {
            XCTAssertFalse(app.buttons[raw].exists, "raw choice \(raw) is not a button title")
        }
        XCTAssertEqual(commandTexts(app).count, 0, "command hidden until Details is opened")
        XCTAssertTrue(app.staticTexts["Needs your OK"].exists, "plain heading\n" + app.debugDescription)
        XCTAssertTrue(app.staticTexts["This could change or delete something. Allow it?"].exists, "plain ask")
        XCTAssertEqual(riskLabels(app).count, 0, "gateway risk label hidden until Details is opened")
        shot(app, "chat-approval-collapsed")

        let details = app.descendants(matching: .any)["approvalDetails"].firstMatch
        XCTAssertTrue(details.exists, app.debugDescription)
        details.tap()
        waitFor(commandTexts(app).firstMatch, timeout: 10, "command shown under Details")
        XCTAssertGreaterThan(riskLabels(app).count, 0, "gateway risk label shown under Details")
        shot(app, "chat-approval-details")

        decline.tap()
        waitGone(allow, timeout: 30, "card removed after answering")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-tool-final").firstMatch, timeout: 60, "turn completes after deny")
    }

    private func toolRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label CONTAINS[c] %@", "Running ", "Used ", "terminal"
        ))
    }

    private func riskLabels(_ app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "destroys uncommitted"))
    }

    private func commandTexts(_ app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "mktemp"))
    }
}
