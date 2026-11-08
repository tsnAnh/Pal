import XCTest

@MainActor
final class PushE2ETests: BotProfileTestCase {
    static let reply = "Finished the report you asked for"

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private func banner() -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", Self.reply))
            .firstMatch
    }

    private func tapBannerAndExpectChat(_ app: XCUIApplication) {
        let banner = banner()
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "notification banner\n" + springboard.debugDescription)
        screenShot("push-banner")
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app in foreground after the tap")
        waitFor(element(app, "chatScreen"), timeout: 40, "chat opened from the notification")
        waitUntil(20, "chat title names the bot") { self.element(app, "chatTitle").label.contains("UA") }
        screenShot("push-chat-opened")
    }

    func test1ForegroundPushShowsAPreviewBannerAndTheTapOpensThatBotsChat() throws {
        let app = signedInApp()
        signalHost("ready-for-push")
        tapBannerAndExpectChat(app)
    }

    func test2BackgroundPushTapOpensThatBotsChat() throws {
        let app = signedInApp()
        XCUIDevice.shared.press(.home)
        signalHost("ready-for-push")
        tapBannerAndExpectChat(app)
    }

    func test3TapOnAPushWhileTheAppIsNotRunningLaunchesIntoThatBotsChat() throws {
        let app = signedInApp()
        app.terminate()
        signalHost("ready-for-push")
        tapBannerAndExpectChat(app)
    }
}
