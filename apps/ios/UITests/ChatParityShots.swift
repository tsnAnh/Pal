import HermesDesign
import XCTest

@MainActor
final class ChatParityShots: E2ETestCase {
    private static let settleDelay: TimeInterval = 2
    private static let unreadWindow: TimeInterval = 3 * 3600

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    private func openChat(_ slug: String, lastSeenAgo: TimeInterval? = nil) -> XCUIApplication {
        var arguments = ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue]
        if let lastSeenAgo {
            arguments += ["-hermes.chat.lastSeen.\(slug)", String(Date().addingTimeInterval(-lastSeenAgo).timeIntervalSince1970)]
        }
        let app = launch(extraArguments: arguments)
        signInIfNeeded(app)
        openBot(app, slug)
        return app
    }

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        let chat = app.descendants(matching: .any)["chatScreen"]
        chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        let latest = app.buttons["scrollToBottomButton"]
        if latest.waitForExistence(timeout: 2) { latest.tap() }
    }

    private func scrollUp(_ app: XCUIApplication, swipes: Int) {
        let chat = app.descendants(matching: .any)["chatScreen"]
        for _ in 0..<swipes { chat.swipeDown(velocity: .fast) }
    }

    func test39BotToBotThread() throws {
        let app = openChat("cho-research-app")
        let link = app.buttons["botThreadLink"].firstMatch
        waitFor(link, timeout: 30, "bot thread link row")
        link.tap()
        waitFor(app.descendants(matching: .any)["threadScreen"], timeout: 20, "read-only thread screen")
        waitFor(app.descendants(matching: .any)["threadReadOnlyPill"], timeout: 10, "read-only pill")
        waitFor(app.descendants(matching: .any)["threadMessage"].firstMatch, timeout: 20, "thread messages")
        parityShot("39-bot-to-bot-thread")
    }

    func test9CheckingMessages() throws {
        let app = openChat("cho-ua")
        send(app, "HOLD checking")
        waitFor(app.descendants(matching: .any)["assistantBubble-streaming"], timeout: 20, "working row while the bot works")
        dismissKeyboard(app)
        parityShot("11-chat-checking-messages")
    }

    func test12NewDivider() throws {
        let app = openChat("cho-ua", lastSeenAgo: Self.unreadWindow)
        waitFor(app.descendants(matching: .any)["unreadDivider"], timeout: 20, "unread divider above the first unread message")
        parityShot("12-chat-new-divider")
    }

    func test13ScrollBullets() throws {
        let app = openChat("cho-ua")
        scrollUp(app, swipes: 4)
        waitFor(app.descendants(matching: .any)["scrollToBottomButton"], timeout: 10, "scroll-to-bottom button once scrolled up")
        parityShot("13-chat-scroll-bullets")
    }

    func test14PrimaryBot() throws {
        let app = openChat("default")
        scrollUp(app, swipes: 1)
        waitFor(app.descendants(matching: .any)["scrollToBottomButton"], timeout: 10, "scroll-to-bottom button once scrolled up")
        parityShot("14-chat-primary-bot")
    }

    func test25ChatMenu() throws {
        let app = openChat("default")
        app.buttons["chatMenuButton"].tap()
        waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
        parityShot("25-chat-menu")
    }
}
