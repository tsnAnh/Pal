import XCTest

@MainActor
final class SlackLinkE2ETests: BotProfileTestCase {
    func testTokensThatNeverStartSettleOnTheirReasonWithRetry() throws {
        let app = signedInApp(connectedServices: ["slack"])
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        let connect = element(app, "slackConnectButton")
        waitFor(connect, timeout: 30, "connect button")
        connect.tap()
        waitFor(element(app, "slackTokenEntry"), timeout: 15, "token entry")
        let bot = app.secureTextFields["slackBotToken"]
        bot.tap()
        bot.typeText("xoxb-1111111111-fixture")
        let appToken = app.secureTextFields["slackAppToken"]
        appToken.tap()
        appToken.typeText("xapp-1-fixture")
        element(app, "slackTokenSubmit").tap()
        waitFor(element(app, "slackSetupFrame"), timeout: 30, "the Slack status screen")
        shot(app, "slack-link-connecting")
        let stalled = element(app, "slackStatusStalled")
        let failed = element(app, "slackStatusFailed")
        waitUntil(120, "the screen settles on a reason instead of Connecting forever") { stalled.exists || failed.exists }
        XCTAssertFalse(element(app, "slackBusy").exists, "no permanently busy button")
        XCTAssertFalse(element(app, "slackFailureReason").label.isEmpty, "the real reason is shown")
        let retry = element(app, "slackRetryButton")
        XCTAssertTrue(retry.exists, "Retry is offered")
        XCTAssertTrue(element(app, "slackUpdateTokensButton").exists, "tokens stay reachable")
        shot(app, "slack-link-settled")
        retry.tap()
        waitUntil(120, "Retry checks again and settles again") {
            (stalled.exists || failed.exists) && element(app, "slackRetryButton").exists
        }
    }
}
