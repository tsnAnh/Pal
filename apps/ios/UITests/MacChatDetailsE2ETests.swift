#if os(macOS)
import AppKit
import HermesDesign
import XCTest

@MainActor
final class MacChatDetailsE2ETests: BotProfileTestCase {
    private static let bot = "bot-beta"

    private func expandedSidebar(_ app: XCUIApplication) -> XCUIElement { element(app, "sidebarExpanded") }

    private func inEachAppearance(_ scenario: (XCUIApplication, String) -> Void) {
        for mode in [AppearanceMode.dark, .light] {
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            app.activate()
            signInIfNeeded(app)
            app.activate()
            let anyBotRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch
            waitFor(anyBotRow, timeout: 30, "roster rows")
            if element(app, "sidebarRail").exists {
                app.typeKey("b", modifierFlags: .command)
                waitFor(expandedSidebar(app), timeout: 10, "expanded sidebar")
            }
            scenario(app, mode.rawValue)
            app.terminate()
        }
    }

    private func newestReply(_ app: XCUIApplication) -> XCUIElement {
        let replies = app.descendants(matching: .any).matching(identifier: "assistantBubble")
        return replies.element(boundBy: replies.count - 1)
    }

    private func hover(_ app: XCUIApplication, _ element: XCUIElement) {
        app.activate()
        Thread.sleep(forTimeInterval: 1)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).hover()
        Thread.sleep(forTimeInterval: 0.4)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func converse(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        openBot(app, Self.bot)
        send(app, text)
        waitFor(bubbles(app, "userBubble", containing: text).firstMatch, timeout: 20, "user bubble for \(text)")
        let reply = waitForReply(app, below: text)
        XCTAssertNotNil(reply)
        Thread.sleep(forTimeInterval: 0.6)
        return newestReply(app)
    }


    func test1HoverActionsAppearAndCopyPutsTheReplyOnThePasteboard() throws {
        inEachAppearance { app, suffix in
            let reply = converse(app, "hover copy \(suffix)")
            XCTAssertFalse(element(app, "messageActionBar").exists, "no action bar before hovering")
            hover(app, reply)
            waitFor(element(app, "messageActionBar"), timeout: 10, "hover action bar")
            waitFor(element(app, "messageReact"), timeout: 5, "react button")
            waitFor(element(app, "messageReply"), timeout: 5, "reply button")
            waitFor(element(app, "messageMore"), timeout: 5, "more button")
            shot(app, "mac-chat-hover-actions-\(suffix)")

            NSPasteboard.general.clearContents()
            element(app, "messageMore").hit()
            let copy = element(app, "contextCopy")
            waitFor(copy, timeout: 10, "copy item")
            waitFor(element(app, "contextReply"), timeout: 5, "reply item in the same menu")
            shot(app, "mac-chat-more-menu-\(suffix)")
            copy.hit()
            waitGone(element(app, "messageContextMenu"), timeout: 10, "menu closes after copying")
            waitUntil(10, "reply text is on the pasteboard") {
                NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == reply.label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("stub-") ?? false)
        }
    }

    func test2ContextMenuReplySetsTheComposerReplyTarget() throws {
        inEachAppearance { app, suffix in
            let reply = converse(app, "reply target \(suffix)")
            reply.rightClick()
            let replyItem = element(app, "contextReply")
            waitFor(replyItem, timeout: 10, "context menu Reply")
            waitFor(element(app, "contextCopy"), timeout: 5, "context menu Copy")
            waitFor(element(app, "contextReaction-👍"), timeout: 5, "context menu reactions")
            shot(app, "mac-chat-context-menu-\(suffix)")
            replyItem.hit()
            let bar = element(app, "replyBar")
            waitFor(bar, timeout: 10, "reply bar above the composer")
            XCTAssertTrue(bar.descendants(matching: .staticText).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "stub-", "stub-")).count > 0, "the bar quotes the reply\n" + app.debugDescription)
            shot(app, "mac-chat-reply-target-\(suffix)")

            let field = element(app, "composerField")
            field.hit()
            field.typeText("answering that \(suffix)")
            app.buttons["sendButton"].hit()
            let sent = bubbles(app, "userBubble", containing: "answering that").firstMatch
            waitFor(sent, timeout: 15, "reply sent")
            XCTAssertTrue(sent.label.hasPrefix("stub-"), "the bubble leads with the quoted text: \(sent.label)")
            XCTAssertFalse(sent.label.contains("> "), "the raw quote marker is not shown: \(sent.label)")
            XCTAssertTrue(sent.label.contains("answering that"), sent.label)
            shot(app, "mac-chat-reply-quote-\(suffix)")
            waitGone(element(app, "replyBar"), timeout: 10, "reply bar clears after sending")
            _ = waitForReply(app, below: "answering that")
        }
    }

    func test3ReactionFromTheHoverBarApplies() throws {
        inEachAppearance { app, suffix in
            let reply = converse(app, "react \(suffix)")
            hover(app, reply)
            waitFor(element(app, "messageReact"), timeout: 10, "react button")
            element(app, "messageReact").hit()
            let thumbs = element(app, "contextReaction-👍")
            waitFor(thumbs, timeout: 10, "reaction choices")
            thumbs.hit()
            let badge = element(app, "messageReaction")
            waitFor(badge, timeout: 15, "reaction badge")
            XCTAssertEqual(badge.label, "👍")
            shot(app, "mac-chat-reaction-\(suffix)")

            hover(app, reply)
            waitFor(element(app, "messageReact"), timeout: 10, "react button again")
            element(app, "messageReact").hit()
            waitFor(element(app, "contextReaction-👍"), timeout: 10, "reaction choices again")
            element(app, "contextReaction-👍").hit()
            waitGone(element(app, "messageReaction"), timeout: 15, "same reaction retracts")
        }
    }

    func test4ComposerPlusMenuOffersAttachments() throws {
        inEachAppearance { app, suffix in
            openBot(app, Self.bot)
            let plus = element(app, "attachButton")
            waitFor(plus, timeout: 10, "plus button")
            plus.hit()
            let attach = element(app, "attachFiles")
            waitFor(attach, timeout: 10, "Attach files item")
            waitFor(element(app, "attachPhotos"), timeout: 5, "Photo Library item")
            XCTAssertLessThan(attach.frame.maxY, plus.frame.minY, "the menu opens above the composer")
            shot(app, "mac-chat-composer-plus-\(suffix)")
            app.typeKey(.escape, modifierFlags: [])
            waitGone(attach, timeout: 10, "menu closes")
        }
    }

    func test5WorkingStatusAndThinkingLineShowWhileTheBotWorks() throws {
        inEachAppearance { app, suffix in
            openBot(app, Self.bot)
            let slow = "SLOW working \(suffix)"
            send(app, slow)
            let thinking = element(app, "thinkingLine")
            waitFor(thinking, timeout: 60, "thinking line during a slow reply")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Putting it together", "Putting it together")).count > 0, app.debugDescription)
            Thread.sleep(forTimeInterval: 1.2)
            shot(app, "mac-chat-thinking-\(suffix)")
            waitForReply(app, below: slow, timeout: 90)
            waitGone(thinking, timeout: 15, "thinking line leaves when the reply lands")

            send(app, "TOOLCALL working \(suffix)")
            let status = element(app, "workingStatus")
            waitFor(status, timeout: 60, "status line while a tool runs")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Running a command", "Running a command")).count > 0, app.debugDescription)
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "mac-chat-working-status-\(suffix)")
            waitFor(bubbles(app, "assistantBubble", containing: "stub-tool-final").firstMatch, timeout: 90, "tool turn completes")
            waitGone(status, timeout: 15, "status line leaves when the turn ends")
        }
    }

    func test6SidebarBotContextMenuOpens() throws {
        inEachAppearance { app, suffix in
            let row = app.buttons["botRow-\(Self.bot)"]
            waitFor(row, timeout: 30, "bot row")
            row.rightClick()
            waitFor(app.menuItems["View Profile"], timeout: 10, "View Profile item")
            waitFor(app.menuItems["Pin"], timeout: 5, "Pin item")
            shot(app, "mac-chat-bot-context-menu-\(suffix)")
            app.typeKey(.escape, modifierFlags: [])
            waitGone(app.menuItems["View Profile"], timeout: 10, "menu closes")

            let primary = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
                .min { $0.frame.minY < $1.frame.minY }
            let lead = try? XCTUnwrap(primary)
            lead?.rightClick()
            waitFor(app.menuItems["View Profile"], timeout: 10, "primary tile menu")
            shot(app, "mac-chat-primary-context-menu-\(suffix)")
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
#endif
