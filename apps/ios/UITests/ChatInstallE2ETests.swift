import XCTest

@MainActor
final class ChatInstallE2ETests: BotProfileTestCase {
    private static let scripted = ["-hermes-test-chat-install"]
    private static let filler = String(repeating: "TEST", count: 4)
    private static let access = ["xoxe.xoxp", "1", filler].joined(separator: "-")
    private static let refresh = ["xoxe", "1", filler].joined(separator: "-")
    private static let appKey = ["xapp", "1", filler].joined(separator: "-")

    private func openSetup(_ app: XCUIApplication) {
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        waitFor(element(app, "stepFlow"), timeout: 30, "setup screen")
    }

    private func primary(_ app: XCUIApplication, _ label: String) {
        let button = element(app, "stepFlowPrimary")
        waitUntil(20, "primary reads \(label)") { button.exists && button.label.contains(label) && button.isEnabled }
        button.hit()
    }

    private func type(_ app: XCUIApplication, _ field: String, _ text: String) {
        let input = app.secureTextFields["stepFlowField-\(field)"]
        waitFor(input, timeout: 20, "\(field) field")
        input.tap()
        input.typeText(text)
        waitUntil(10, "\(field) reads as valid") { element(app, "stepFlowHint-\(field)").label == "Looks right" }
    }

    private func assertOneWayOut(_ app: XCUIApplication, _ screen: String) {
        #if os(iOS)
        let bar = app.navigationBars.firstMatch
        if bar.exists {
            XCTAssertLessThanOrEqual(bar.buttons.count, 1, "\(screen) has one back or close control")
        }
        #endif
        XCTAssertFalse(app.buttons["chevron.left"].exists, "\(screen) draws no custom back")
    }

    func testSetupWalksFromFirstRunToTheSettingsPageWithResumeAndPrivateInvite() throws {
        var app = signedInApp(connectedServices: ["slack"], extraArguments: Self.scripted + ["-hermes-test-chat-install-reset"])
        openSetup(app)
        walkToTheAppKey(app)
        app.terminate()
        app = signedInApp(connectedServices: ["slack"], extraArguments: Self.scripted)
        openSetup(app)
        resumeThroughAllow(app)
        pickChannels(app)
        finishAndDisconnect(app)
    }

    private func walkToTheAppKey(_ app: XCUIApplication) {
        waitFor(element(app, "slackIntroCard"), timeout: 20, "what you do and what Pal does")
        XCTAssertTrue(element(app, "slackSetupAdvanced").exists, "advanced paste tokens fallback")
        assertOneWayOut(app, "intro")
        shot(app, "slack-setup-intro")
        primary(app, "Start")

        let opened = element(app, "externalLinkProbe")
        element(app, "stepFlowPage").hit()
        waitUntil(20, "slack apps page opened") { opened.label.hasPrefix("https://api.slack.com/apps") }
        XCTAssertFalse(element(app, "stepFlowPrimary").isEnabled, "the tokens are needed first")
        type(app, "access", Self.access)
        type(app, "refresh", Self.refresh)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", Self.filler)).firstMatch.exists, "no token text on screen")
        assertOneWayOut(app, "credential")
        shot(app, "slack-setup-credential")
        primary(app, "Use these tokens")

        waitFor(element(app, "slackSaveAvatar"), timeout: 30, "picture step after the app is created")
        assertOneWayOut(app, "picture")
        shot(app, "slack-setup-picture")
        primary(app, "Done")
        waitFor(app.secureTextFields["stepFlowField-app_key"], timeout: 20, "app key step")
    }

    private func resumeThroughAllow(_ app: XCUIApplication) {
        waitFor(app.secureTextFields["stepFlowField-app_key"], timeout: 30, "resumed on the app key step")
        let position = element(app, "stepFlowPosition")
        if position.exists { XCTAssertEqual(position.label, "Step 4 of 7", "the step bar shows where you are") }
        type(app, "app_key", Self.appKey)
        shot(app, "slack-setup-app-key")
        primary(app, "Done")

        waitFor(element(app, "slackCopyAdminMessage"), timeout: 20, "allow step")
        assertOneWayOut(app, "allow")
        shot(app, "slack-setup-allow")
        primary(app, "Open Slack to allow")
        let opened = element(app, "externalLinkProbe")
        waitUntil(20, "authorize link opened in the system browser") { opened.label.contains("oauth/v2/authorize") }
    }

    private func pickChannels(_ app: XCUIApplication) {
        waitFor(element(app, "slackChannel-C1"), timeout: 40, "channels after Slack finished")
        element(app, "slackChannel-C1").hit()
        waitUntil(20, "public channel joined") { element(app, "slackChannel-C1").value as? String == "On" }
        element(app, "slackChannel-G1").hit()
        waitFor(element(app, "slackInvite-G1Button"), timeout: 20, "private channel shows its invite message")
        XCTAssertTrue(element(app, "slackOpenChannel-G1").exists)
        shot(app, "slack-setup-private-invite")
        element(app, "slackRefreshChannels").hit()
        waitUntil(20, "private channel on after invite") { element(app, "slackChannel-G1").value as? String == "On" }
        primary(app, "Finish")
    }

    private func finishAndDisconnect(_ app: XCUIApplication) {
        waitFor(element(app, "slackSettings"), timeout: 20, "settings page")
        XCTAssertTrue(element(app, "slackSettingsWorkspace").exists)
        assertOneWayOut(app, "settings")
        shot(app, "slack-setup-settings")

        element(app, "slackDisconnect").hit()
        let confirm = element(app, "slackDisconnectConfirm")
        waitFor(confirm, timeout: 10, "disconnect confirmation")
        confirm.hit()
        waitFor(element(app, "slackIntroCard"), timeout: 20, "back to the start after disconnect")
    }
}
