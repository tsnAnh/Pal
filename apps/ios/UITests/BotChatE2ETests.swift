import XCTest

@MainActor
final class BotChatE2ETests: E2ETestCase {
    func test1RosterShowsBothBots() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        for (name, title) in [("bot-alpha", "Bot Alpha"), ("bot-beta", "Bot Beta")] {
            let row = app.buttons["botRow-\(name)"]
            waitFor(row, timeout: 30, "row \(name)")
            #if os(macOS)
            XCTAssertGreaterThanOrEqual(row.frame.height, 50)
            #else
            XCTAssertGreaterThanOrEqual(row.frame.height, 56)
            #endif
            XCTAssertTrue(row.label.contains(title), row.label)
        }
        shot(app, "roster")
        let launcher = app.buttons["rosterSearchField"]
        waitFor(launcher, timeout: 10, "search launcher")
        launcher.hit()
        let search = app.descendants(matching: .any)["searchField"]
        waitFor(search, timeout: 10, "search field")
        #if os(iOS)
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard")
        #endif
        search.typeText("alpha")
        waitFor(app.buttons["searchResult-bot-bot-alpha"], timeout: 10, "search finds the bot")
        waitGone(app.buttons["searchResult-bot-bot-beta"], timeout: 10, "search filters bots")
        shot(app, "roster-search")
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        app.buttons["searchClose"].hit()
        #endif
        waitFor(app.buttons["botRow-bot-alpha"], timeout: 10, "roster after closing search")
    }

    func test2SendStreamsReply() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "hello beta")
        waitFor(bubbles(app, "userBubble", containing: "hello beta").firstMatch, timeout: 10, "user bubble")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60, "streamed reply")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "hello beta").count, 1)
        shot(app, "chat-reply")
    }

    func test3ClarifyCardAndComposerAnswer() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "CLARIFY pick one")
        let card = app.descendants(matching: .any)["clarifyCard"]
        waitFor(card, timeout: 60, "clarify card")
        XCTAssertTrue(app.staticTexts["Which flavor do you want?"].exists)
        XCTAssertTrue(app.staticTexts["Or answer in the chat below"].exists)
        shot(app, "chat-clarify")
        app.buttons["clarifyChoice-0"].hit()
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, vanilla").firstMatch, timeout: 60, "card answer completes the turn")
        waitGone(card, timeout: 15, "interactive card removed after answer")
        waitFor(bubbles(app, "clarifyAnswered", containing: "vanilla").firstMatch, timeout: 10, "answered card stays")

        send(app, "CLARIFY again")
        waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 60, "second clarify card")
        send(app, "chocolate")
        waitFor(bubbles(app, "assistantBubble", containing: "Got it, chocolate").firstMatch, timeout: 60, "composer answer completes the turn")
        waitFor(bubbles(app, "clarifyAnswered", containing: "chocolate").firstMatch, timeout: 10, "composer answer is shown on the answered card")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "chocolate").count, 0, "answer is not a new chat message")
    }

    func test4RelaunchMidStreamKeepsOneReply() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "SLOW stream please")
        waitFor(app.descendants(matching: .any)["assistantBubble-streaming"], timeout: 60, "streaming bubble")
        app.terminate()

        let relaunched = launch()
        signInIfNeeded(relaunched)
        openBot(relaunched, "bot-beta")
        waitFor(bubbles(relaunched, "assistantBubble", containing: "slow-39").firstMatch, timeout: 90, "stream finished after relaunch")
        XCTAssertEqual(bubbles(relaunched, "userBubble", containing: "SLOW stream please").count, 1)
        XCTAssertEqual(bubbles(relaunched, "assistantBubble", containing: "slow-").count, 1)
        XCTAssertFalse(relaunched.descendants(matching: .any)["assistantBubble-streaming"].exists)
    }

    func test5OfflineSendDeliversOnce() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        try control("kill-gateway")
        waitFor(app.descendants(matching: .any)["reconnectingIndicator"], timeout: 30, "reconnecting indicator")
        send(app, "OFFLINE-PING-7731")
        let queued = app.descendants(matching: .any)["deliveryQueued"]
        waitFor(queued, timeout: 15, "queued state")
        shot(app, "chat-queued")
        try control("start-gateway")
        waitGone(queued, timeout: 90, "queued state clears after reconnect")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60)
        XCTAssertEqual(bubbles(app, "userBubble", containing: "OFFLINE-PING-7731").count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["reconnectingIndicator"].exists)
        try control("count-offline-ping")
    }

    func test6DynamicTypeExtraLarge() throws {
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"])
        signInIfNeeded(app)
        waitFor(app.buttons["botRow-bot-beta"], timeout: 30)
        shot(app, "roster-dynamic-type-xl")
        openBot(app, "bot-beta")
        send(app, "CLARIFY large text")
        waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 60, "clarify card")
        shot(app, "chat-clarify-dynamic-type-xl")
        app.buttons["clarifySkip"].hit()
        waitGone(app.descendants(matching: .any)["clarifyCard"], timeout: 15, "card skipped so the chat is left clean")
    }

    func test7ReopenLongChatStartsAtBottom() throws {
        let firstLaunch = launch()
        signInIfNeeded(firstLaunch)
        openBot(firstLaunch, "bot-alpha")
        let turns = 14
        for index in 1...turns {
            let text = String(format: "history-%02d", index)
            send(firstLaunch, text)
            waitFor(bubbles(firstLaunch, "userBubble", containing: text).firstMatch, timeout: 10, "user bubble \(text)")
            waitForReply(firstLaunch, below: text)
        }

        firstLaunch.terminate()
        let app = launch()
        signInIfNeeded(app)
        let row = app.buttons["botRow-bot-alpha"]
        waitFor(row, timeout: 30, "roster row")
        row.hit()

        let chat = app.descendants(matching: .any)["chatScreen"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20), app.debugDescription)
        let newest = bubbles(app, "userBubble", containing: String(format: "history-%02d", turns)).firstMatch
        let oldest = bubbles(app, "userBubble", containing: "history-01").firstMatch
        shot(app, "chat-reopen-first-frame")
        XCTAssertTrue(newest.exists && newest.isHittable, "newest user message is visible at first appearance\n" + app.debugDescription)
        XCTAssertFalse(oldest.exists && oldest.isHittable, "oldest user message is not visible at first appearance")

        let deadline = Date().addingTimeInterval(1.5)
        var samples = 0
        while Date() < deadline {
            XCTAssertTrue(newest.exists && newest.isHittable, "newest user message stays visible, sample \(samples)")
            XCTAssertFalse(oldest.exists && oldest.isHittable, "oldest user message stays off-screen, sample \(samples)")
            samples += 1
        }
        XCTAssertGreaterThanOrEqual(samples, 2)
        let newestReply = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex.last)
        XCTAssertTrue(newestReply.isHittable, "newest reply is visible")
        shot(app, "chat-reopen-settled")
    }

    func test8NewReplyInLongChatScrollsIntoView() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        for index in 1...10 {
            let text = String(format: "fill-%02d", index)
            send(app, text)
            waitFor(bubbles(app, "userBubble", containing: text).firstMatch, timeout: 10, "user bubble \(text)")
            waitForReply(app, below: text)
        }
        let marker = "SLOW grow " + UUID().uuidString.prefix(6)
        send(app, marker)
        waitForReply(app, below: marker)
        let composer = app.descendants(matching: .any)["composerField"]
        let reply = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex.last)
        shot(app, "chat-long-new-reply")
        XCTAssertTrue(reply.label.contains("slow-39"), reply.label)
        XCTAssertTrue(reply.isHittable, "the new reply is on screen")
        XCTAssertLessThanOrEqual(reply.frame.maxY, composer.frame.minY, "the end of the new reply sits above the composer")
    }
}
