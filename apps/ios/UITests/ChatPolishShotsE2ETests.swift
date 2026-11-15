import PalDesign
import XCTest

@MainActor
final class ChatPolishShotsE2ETests: E2ETestCase {
    private func open(_ mode: AppearanceMode, bot: String = "bot-beta") -> XCUIApplication {
        let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
        signInIfNeeded(app)
        openBot(app, bot)
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func settle() { Thread.sleep(forTimeInterval: 1) }

    func test0FreshChatShowsIntroAndNotice() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode)
            waitFor(app.buttons["newChatSuggestion"], timeout: 30, "empty new chat offers a tappable suggestion")
            settle()
            shot(app, "empty-new-chat-\(mode.rawValue)")
            app.buttons["micButton"].tap()
            if element(app, "composerNotice").waitForExistence(timeout: 10) {
                shot(app, "composer-notice-\(mode.rawValue)")
            }
            app.terminate()
        }
    }

    func test1ComposerAndWorkingRow() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode)
            let field = element(app, "composerField")
            waitFor(field, timeout: 30, "composer")
            settle()
            shot(app, "composer-rest-\(mode.rawValue)")
            field.tap()
            settle()
            shot(app, "composer-focused-keyboard-\(mode.rawValue)")
            field.typeText("SLOW a longer draft that wraps onto a second line to check the glass field grows")
            settle()
            shot(app, "composer-text-\(mode.rawValue)")
            app.buttons["sendButton"].tap()
            let working = element(app, "assistantBubble-streaming")
            waitFor(working, timeout: 30, "working row")
            shot(app, "loading-row-thinking-\(mode.rawValue)")
            waitGone(working, timeout: 60, "reply completes")
            send(app, "TOOLCALL check")
            let status = element(app, "workingStatus")
            waitFor(status, timeout: 60, "tool status label")
            shot(app, "loading-row-tool-\(mode.rawValue)")
            waitGone(element(app, "assistantBubble-streaming"), timeout: 90, "tool turn completes")
            app.terminate()
        }
    }

    func test2ApprovalAndAnsweredCard() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode, bot: "bot-alpha")
            send(app, "APPROVE \(mode.rawValue) " + UUID().uuidString.prefix(4))
            let allow = app.buttons["approvalChoice-0"]
            waitFor(allow, timeout: 60, "approval card")
            settle()
            shot(app, "approval-card-\(mode.rawValue)")
            let more = element(app, "approvalMoreOptions")
            if more.exists {
                more.tap()
                settle()
                shot(app, "approval-more-options-\(mode.rawValue)")
            }
            allow.tap()
            let answered = element(app, "approvalAnswered")
            waitFor(answered, timeout: 30, "answered record card")
            XCTAssertTrue(answered.staticTexts["Allow"].exists, "the record names the decision\n" + answered.debugDescription)
            waitFor(bubbles(app, "assistantBubble", containing: "stub-tool-final").firstMatch, timeout: 60, "turn completes after allow")
            settle()
            shot(app, "approval-answered-\(mode.rawValue)")
            app.terminate()
        }
    }

    func test3FindAndPill() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode)
            let marker = "findme" + UUID().uuidString.prefix(4)
            send(app, "\(marker) one \(marker) two")
            _ = waitForReply(app, below: marker, timeout: 60)
            for index in 0..<8 { send(app, "filler \(index)") ; _ = waitForReply(app, below: "filler \(index)", timeout: 60) }
            let chat = element(app, "chatScreen")
            for _ in 0..<3 { chat.swipeDown(velocity: .fast) }
            let pill = app.buttons["scrollToBottomButton"]
            waitFor(pill, timeout: 10, "jump pill")
            settle()
            shot(app, "jump-pill-\(mode.rawValue)")
            pill.tap()
            waitGone(pill, timeout: 10, "pill hides at the newest message")
            app.buttons["chatMenuButton"].tap()
            waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
            app.buttons["chatMenuFind"].tap()
            let field = app.textFields["findField"]
            waitFor(field, timeout: 10, "find field")
            field.typeText(marker)
            settle()
            shot(app, "find-\(mode.rawValue)")
            app.terminate()
        }
    }

    func test4TitleCapsuleOpensProfile() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode)
            let title = app.buttons["chatTitle"]
            waitFor(title, timeout: 30, "title capsule")
            settle()
            shot(app, "chat-header-glass-\(mode.rawValue)")
            title.tap()
            waitFor(element(app, "botProfileScreen"), timeout: 20, "tapping the title capsule opens the bot profile")
            waitFor(element(app, "profileAvatar"), timeout: 20, "profile avatar")
            settle()
            shot(app, "profile-from-capsule-\(mode.rawValue)")
            app.terminate()
        }
    }

    func test5HomeGlass() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            signInIfNeeded(app)
            waitFor(app.buttons["rosterSearchField"], timeout: 30, "home search launcher")
            settle()
            shot(app, "home-glass-\(mode.rawValue)")
            app.terminate()
        }
    }

    func test6WorkingRowLoop() throws {
        for mode in [AppearanceMode.light, .dark] {
            let app = open(mode)
            send(app, "HOLD working row \(mode.rawValue)")
            let working = element(app, "assistantBubble-streaming")
            waitFor(working, timeout: 30, "working row")
            shot(app, "working-row-hold-\(mode.rawValue)")
            Thread.sleep(forTimeInterval: 6)
            XCTAssertTrue(working.exists, "the working row stays while the turn holds")
            waitGone(working, timeout: 60, "reply completes")
            app.terminate()
        }
    }
}
