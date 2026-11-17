import XCTest

@MainActor
final class DiscordSetupE2ETests: ConnectAppsTestCase {
    private let token = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func expectStep(_ app: XCUIApplication, _ id: String) {
        waitFor(element(app, "setupGuideStep-\(id)"), timeout: 20, "step \(id)")
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        waitFor(target, timeout: 15, id)
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        target.hit()
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1" || (toggle.value as? NSNumber)?.intValue == 1
    }

    func testDiscordChecksTheBotPicksServersAndSavesReadOnlyThenTurnsOnWriteWithAConfirmation() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        waitForCatalog(app)
        search(app, "Discord")
        let button = action(app, "discord")
        waitFor(button, timeout: 30, "Discord action")
        button.hit()
        waitFor(element(app, "setupGuide"), timeout: 20, "setup guide")

        expectStep(app, "bot")
        tap(app, "setupGuideLink-0")
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "developer portal handed to the browser") { opened.label.hasPrefix("https://discord.com/developers/applications") }
        tap(app, "setupGuideNext")

        expectStep(app, "token")
        let field = element(app, "setupGuideField-token")
        waitFor(field, timeout: 10, "token field")
        field.hit()
        field.typeText(token)
        XCTAssertFalse(app.staticTexts[token].exists, "the token is never echoed")
        tap(app, "setupGuideSubmit")

        expectStep(app, "invite")
        XCTAssertTrue(element(app, "setupGuideLink-0").exists && element(app, "setupGuideLink-1").exists, "both invite links once the bot is known")
        tap(app, "setupGuideLink-0")
        waitUntil(30, "read-only invite handed to the browser") { opened.label.contains("permissions=66560") }
        tap(app, "setupGuideNext")

        expectStep(app, "servers")
        waitFor(element(app, "setupGuideServer-111"), timeout: 20, "server list")
        XCTAssertFalse(element(app, "setupGuideNext").isEnabled, "at least one server is required")
        tap(app, "setupGuideServer-111")
        shot(app, "setup-guide-discord-servers")
        tap(app, "setupGuideNext")

        expectStep(app, "access")
        let readOnly = element(app, "setupGuideReadOnly")
        waitFor(readOnly, timeout: 10, "read-only switch")
        XCTAssertTrue(isOn(readOnly), "read only is on by default")
        tap(app, "setupGuideSubmit")
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after saving")
        waitLabel(button, contains: "Update token", timeout: 30)

        button.hit()
        expectStep(app, "access")
        readOnly.hit()
        let confirm = app.alerts.firstMatch
        waitFor(confirm, timeout: 10, "write confirmation")
        XCTAssertTrue(confirm.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "delete")).firstMatch.exists, "names the risk")
        shot(app, "setup-guide-discord-write-confirm")
        confirm.buttons["Allow posting"].hit()
        waitUntil(10, "write on") { !isOn(readOnly) }
        tap(app, "setupGuideSubmit")
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after switching to write")
        shot(app, "setup-guide-discord-connected")
    }
}
