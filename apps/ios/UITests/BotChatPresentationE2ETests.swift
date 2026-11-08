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

    func test3AnsweredClarifyStaysOnScreenWithoutRawJSON() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "CLARIFY pick one")
        let card = app.descendants(matching: .any)["clarifyCard"]
        waitFor(card, timeout: 60, "clarify card")
        app.buttons["clarifyChoice-1"].tap()
        waitFor(bubbles(app, "assistantBubble", containing: "chocolate").firstMatch, timeout: 60, "turn completes after the answer")

        let answered = answeredCards(app, containing: "chocolate")
        waitFor(answered.firstMatch, timeout: 10, "answered card shows the question and the pick")
        XCTAssertTrue(answered.firstMatch.label.contains("Which flavor do you want?"), answered.firstMatch.label)
        XCTAssertFalse(card.exists, "interactive card is gone")
        XCTAssertTrue(bubbles(app, "assistantBubble", containing: "Got it, chocolate").firstMatch.exists, "reply is a plain sentence")
        XCTAssertEqual(rawJSONBubbles(app).count, 0, "no raw JSON in any bubble\n" + app.debugDescription)
        shot(app, "chat-clarify-answered")

        app.terminate()
        let relaunched = launch()
        signInIfNeeded(relaunched)
        openBot(relaunched, "bot-beta")
        waitFor(answeredCards(relaunched, containing: "chocolate").firstMatch, timeout: 30, "answered card is still there after relaunch")
        XCTAssertEqual(rawJSONBubbles(relaunched).count, 0, "no raw JSON after relaunch\n" + relaunched.debugDescription)
        shot(relaunched, "chat-clarify-answered-reopened")
    }

    func test4ReplyAppearsWholeAfterThinking() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        let marker = "SLOW show it whole " + UUID().uuidString.prefix(6)
        send(app, marker)
        let sent = bubbles(app, "userBubble", containing: marker).firstMatch
        let streamingPartial = bubbles(app, "assistantBubble-streaming", containing: "slow-")
        let thinking = app.descendants(matching: .any).matching(identifier: "assistantBubble-streaming")
            .matching(NSPredicate(format: "label == %@", "Thinking"))

        var thinkingSamples = 0
        var reply: XCUIElement?
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, reply == nil {
            XCTAssertFalse(streamingPartial.firstMatch.exists, "streaming text is not shown")
            if thinking.firstMatch.exists { thinkingSamples += 1 }
            if let latest = app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex.last,
               sent.exists, latest.frame.minY > sent.frame.minY {
                guard latest.label.contains("slow-39") else {
                    XCTFail("partial reply was shown while streaming: \(latest.label)")
                    return
                }
                reply = latest
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let whole = try XCTUnwrap(reply, "whole reply arrived")
        XCTAssertGreaterThanOrEqual(thinkingSamples, 5, "thinking bubble stays up until the reply is complete")
        XCTAssertTrue(whole.label.contains("slow-00"), "reply starts at its first word")
        waitGone(thinking.firstMatch, timeout: 15, "thinking bubble gone once the reply is shown")
        shot(app, "chat-reply-whole")
    }

    private func answeredCards(_ app: XCUIApplication, containing text: String) -> XCUIElementQuery {
        bubbles(app, "clarifyAnswered", containing: text)
    }

    private func rawJSONBubbles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "assistantBubble", "{", "user_response"
        ))
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
