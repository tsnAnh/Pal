import HermesDesign
import XCTest

@MainActor
final class GrokChatE2ETests: E2ETestCase {
    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    private func openChat(_ slug: String, extra: [String] = []) -> XCUIApplication {
        let app = launch(extraArguments: ["-hermes-reset-preferences", "-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue] + extra)
        signInIfNeeded(app)
        openBot(app, slug)
        return app
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func color(at point: CGPoint, in screenshot: XCUIScreenshot, scale: CGFloat) throws -> RGB {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(hex: UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2]))
    }

    func test1FindInChatHighlightsAndStepsThroughMatches() throws {
        let app = openChat("cho-ua")
        app.buttons["chatMenuButton"].tap()
        waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
        XCTAssertTrue(app.buttons["chatMenuViewProfile"].exists, "View Profile opens the bot profile route")
        XCTAssertTrue(app.buttons["chatMenuShareTemplate"].exists, "Share as Template uses the registered template sharer")
        app.buttons["chatMenuFind"].tap()

        let field = app.textFields["findField"]
        waitFor(field, timeout: 10, "find field")
        field.typeText("igloo")
        let count = any(app, "findCount")
        waitFor(count, timeout: 10, "match counter")
        XCTAssertEqual(count.label, "2 of 2", "newest match is current first")
        shot(app, "find-igloo-current")
        app.buttons["findPrevious"].tap()
        XCTAssertEqual(any(app, "findCount").label, "1 of 2")
        shot(app, "find-igloo-previous")
        app.buttons["findNext"].tap()
        XCTAssertEqual(any(app, "findCount").label, "2 of 2")

        field.clearAndType("zzzz-no-such-word")
        XCTAssertEqual(any(app, "findCount").label, "No results")

        app.buttons["findDone"].tap()
        waitFor(any(app, "composerField"), timeout: 10, "composer returns after Done")
    }

    func test2InboundBotRowsAreNotHumanBubbles() throws {
        let app = openChat("cho-ua")
        let notice = any(app, "inboundNotice")
        waitFor(notice, timeout: 20, "system notice rows")
        let labels = app.descendants(matching: .any).matching(identifier: "inboundNotice").allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("Message from chó ai image gen"), "\(labels)")
        XCTAssertTrue(labels.contains("Background task finished"), "\(labels)")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "Message from").count, 0, "bot-to-bot rows are not the human's bubbles")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "IMPORTANT: Background process").count, 0)
        shot(app, "inbound-rows")
    }

    func test3SendShowsAccentBubbleOnTheRightAndStreamedReplyOnTheLeft() throws {
        let app = openChat("cho-ua")
        let text = "hello accent \(UUID().uuidString.prefix(8))"
        send(app, text)
        let user = bubbles(app, "userBubble", containing: text).firstMatch
        waitFor(user, timeout: 15, "user bubble")
        let reply = try XCTUnwrap(waitForReply(app, below: text), "streamed reply")
        let width = app.frame.width
        XCTAssertGreaterThan(user.frame.midX, width / 2, "user bubble sits on the right")
        XCTAssertLessThan(reply.frame.midX, width / 2, "assistant bubble sits on the left")
        XCTAssertLessThan(reply.frame.maxX, width - 40, "assistant bubbles leave the trailing gap")
        let screenshot = app.screenshot()
        let scale = CGFloat(screenshot.image.cgImage?.width ?? Int(width)) / width
        let sample = try color(at: CGPoint(x: user.frame.minX + 5, y: user.frame.midY), in: screenshot, scale: scale)
        let accent = try XCTUnwrap(RGB(hexString: "#ed0a37"))
        let delta = max(abs(sample.red - accent.red), abs(sample.green - accent.green), abs(sample.blue - accent.blue))
        XCTAssertLessThan(delta, 0.05, "user bubble is filled with the bot accent, rendered \(sample.hexString)")
        shot(app, "send-accent")
    }

    func test4PhotoLibraryAttachmentIsSent() throws {
        let app = openChat("cho-ua")
        app.buttons["attachButton"].tap()
        waitFor(app.buttons["attachPhotos"], timeout: 10, "attach menu")
        app.buttons["attachPhotos"].tap()
        let image = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        waitFor(image, timeout: 30, "photo library picker")
        image.tap()
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 5) { add.tap() }
        waitFor(any(app, "attachmentChip"), timeout: 20, "attachment chip")
        waitGone(any(app, "attachmentUploading"), timeout: 60, "upload finishes")
        shot(app, "attachment-ready")
        let field = any(app, "composerField")
        field.tap()
        let caption = "PHOTO-CAPTION-\(UUID().uuidString.prefix(8))"
        field.typeText(caption)
        app.buttons["sendButton"].tap()
        waitFor(bubbles(app, "userBubble", containing: caption).firstMatch, timeout: 20, "caption bubble")
        waitForReply(app, below: caption)
        waitGone(any(app, "attachmentChip"), timeout: 10, "tray clears after sending")
        shot(app, "attachment-sent")
    }

    func test5VoiceModeOpensAndCloses() throws {
        let app = openChat("cho-ua")
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.tap()
                return true
            }
            return false
        }
        app.buttons["voiceModeButton"].tap()
        let status = any(app, "voiceModeStatus")
        waitFor(status, timeout: 15, "voice mode screen")
        app.tap()
        Thread.sleep(forTimeInterval: 3)
        shot(app, "voice-mode-\(status.label.replacingOccurrences(of: " ", with: "-"))")
        app.buttons["voiceModeClose"].tap()
        waitFor(any(app, "composerField"), timeout: 10, "chat returns after closing voice mode")
    }

    func test7BotToBotLinkOpensTheReadOnlyThreadAtTheTappedExchange() throws {
        let app = openChat("cho-research-app")
        let link = app.buttons["botThreadLink"].firstMatch
        waitFor(link, timeout: 30, "bot thread link row")
        XCTAssertEqual(link.label, "4 messages with Market Researcher")
        XCTAssertEqual(bubbles(app, "userBubble", containing: "Final verification for Soully").count, 0, "covered rows are folded into the link")
        shot(app, "thread-link-row")
        link.tap()

        waitFor(any(app, "threadScreen"), timeout: 20, "thread screen")
        waitFor(any(app, "threadReadOnlyPill"), timeout: 10, "read-only pill")
        XCTAssertFalse(any(app, "composerField").exists, "a thread has no composer")
        XCTAssertFalse(app.buttons["sendButton"].exists)
        waitFor(bubbles(app, "threadMessage", containing: "Final verification for Soully").firstMatch, timeout: 20, "the tapped exchange's first message")
        waitFor(bubbles(app, "threadMessage", containing: "7.1/10").firstMatch, timeout: 20, "the reply")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "threadSenderName").count, 2)
        XCTAssertEqual(any(app, "threadTitle").label, "chó research app and Market Researcher")
        shot(app, "thread-open")

        app.navigationBars.buttons.firstMatch.tap()
        waitFor(any(app, "composerField"), timeout: 10, "chat returns after back")
    }

    func test8ReceivingSideShowsItsOwnLinkAndTheSameThread() throws {
        let app = openChat("market-researcher")
        let link = app.buttons["botThreadLink"].firstMatch
        waitFor(link, timeout: 30, "bot thread link row")
        XCTAssertEqual(link.label, "4 messages with chó research app")
        link.tap()
        waitFor(bubbles(app, "threadMessage", containing: "7.1/10").firstMatch, timeout: 20, "the reply read from the other side")
        shot(app, "thread-receiver-side")
    }

    func test6DictationStartsOrExplainsWhyNot() throws {
        let app = openChat("cho-ua")
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.tap()
                return true
            }
            return false
        }
        let mic = app.buttons["micButton"]
        mic.tap()
        let unavailable = app.alerts["Dictation unavailable"]
        var listening = false
        var explained = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !listening && !explained {
            listening = mic.label == "Stop dictation"
            explained = unavailable.exists
            if !listening && !explained {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        shot(app, "dictation-\(listening ? "listening" : "unavailable")")
        XCTAssertTrue(listening || explained, "dictation either listens or explains why not")
        if unavailable.exists { unavailable.buttons["OK"].tap() }
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let existing = value as? String, !existing.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        typeText(text)
    }
}
