import XCTest

@MainActor
final class DiscordSetupE2ETests: ConnectAppsTestCase {
    private let token = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"
    private let rows = ["bot", "token", "intents", "invite", "access"]

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openFlow(_ app: XCUIApplication) -> XCUIElement {
        waitForCatalog(app)
        search(app, "Discord")
        let button = action(app, "discord")
        waitFor(button, timeout: 30, "Discord action")
        button.hit()
        waitFor(element(app, "stepFlow"), timeout: 20, "step flow")
        return button
    }

    private func expectStep(_ app: XCUIApplication, _ number: Int, _ title: String) {
        let heading = element(app, "stepFlowStepTitle")
        waitFor(heading, timeout: 30, "step \(number)")
        waitUntil(20, "step \(number) reads \(title)") { heading.label == title }
        let position = element(app, "stepFlowPosition")
        if position.exists {
            XCTAssertEqual(position.label, "Step \(number) of 5", "the segments say where you are")
        } else {
            XCTAssertTrue(element(app, "stepFlowRow-\(rows[number - 1])").exists, "the checklist lists step \(number)")
        }
    }

    private func primary(_ app: XCUIApplication) -> XCUIElement {
        let button = element(app, "stepFlowPrimary")
        waitFor(button, timeout: 15, "primary action")
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        return button
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1" || (toggle.value as? NSNumber)?.intValue == 1
    }

    private func enterToken(_ app: XCUIApplication, _ text: String) {
        let field = element(app, "stepFlowField-token")
        waitFor(field, timeout: 10, "token field")
        field.hit()
        field.typeText(text)
        XCTAssertFalse(app.staticTexts[text].exists, "the token is never echoed")
    }

    private func passTheToken(_ app: XCUIApplication) {
        expectStep(app, 1, "Create your Discord bot")
        primary(app).hit()
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "developer portal handed to the browser") { opened.label.hasPrefix("https://discord.com/developers/applications") }
        expectStep(app, 2, "Paste the bot token")
        enterToken(app, token)
        primary(app).hit()
        expectStep(app, 3, "Turn on Message Content")
    }

    func testDiscordRunsFiveStepsThenSavesReadOnlyAndAllowsPostingOnlyAfterAConfirmation() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let button = openFlow(app)
        shot(app, "discord-flow-step-1")

        passTheToken(app)
        XCTAssertFalse(primary(app).isEnabled, "the box must be ticked first")
        element(app, "stepFlowConfirm-message_content").hit()
        XCTAssertTrue(primary(app).isEnabled)
        shot(app, "discord-flow-step-3")
        primary(app).hit()

        expectStep(app, 4, "Invite your bot to a server")
        waitFor(element(app, "stepFlowCopy-0"), timeout: 20, "invite link card")
        XCTAssertTrue(element(app, "stepFlowCopy-0Value").label.contains("permissions=66560"), "the read-only link comes first")
        XCTAssertTrue(element(app, "stepFlowRecheck").exists, "Check again is the quiet link")
        shot(app, "discord-flow-step-4")
        primary(app).hit()
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "invite link handed to the browser") { opened.label.contains("permissions=66560") }

        expectStep(app, 5, "What may the bot do?")
        let readOnly = element(app, "stepFlowSwitch-read_only")
        waitFor(readOnly, timeout: 20, "read-only switch")
        XCTAssertTrue(isOn(readOnly), "read only is on by default")
        XCTAssertFalse(primary(app).isEnabled, "at least one server is required")
        element(app, "stepFlowSwitch-guild.111").hit()
        XCTAssertTrue(primary(app).isEnabled)
        shot(app, "discord-flow-step-5")
        primary(app).hit()

        waitFor(element(app, "stepFlowSuccess"), timeout: 60, "connected screen")
        primary(app).hit()
        waitGone(element(app, "stepFlow"), timeout: 30, "the flow closes")
        waitLabel(button, contains: "Connected", timeout: 30)

        button.hit()
        expectStep(app, 5, "What may the bot do?")
        let again = element(app, "stepFlowSwitch-read_only")
        waitFor(again, timeout: 20, "read-only switch again")
        again.hit()
        let confirm = app.alerts.firstMatch
        waitFor(confirm, timeout: 10, "write confirmation")
        XCTAssertTrue(confirm.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "delete")).firstMatch.exists, "names the risk")
        shot(app, "discord-flow-write-confirm")
        confirm.buttons["Allow posting"].hit()
        waitUntil(10, "write on") { !self.isOn(again) }
        primary(app).hit()
        waitFor(element(app, "stepFlowSuccess"), timeout: 60, "connected screen after allowing posting")
        shot(app, "discord-flow-connected")
    }

    func testARefusedTokenSaysWhatIsWrongOnTheFieldAndStaysOnTheStep() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        _ = openFlow(app)
        expectStep(app, 1, "Create your Discord bot")
        primary(app).hit()
        expectStep(app, 2, "Paste the bot token")

        enterToken(app, "MTA1")
        waitFor(element(app, "stepFlowHint-token"), timeout: 10, "live hint for a short token")
        XCTAssertFalse(primary(app).isEnabled, "a token of one part is never sent")
        element(app, "stepFlowField-token").typeText(".Grejected.fake-token-do-not-use-000000")
        XCTAssertTrue(primary(app).isEnabled)
        primary(app).hit()

        let refusal = element(app, "stepFlowRefusal")
        waitFor(refusal, timeout: 30, "refusal on the field")
        XCTAssertTrue(refusal.label.hasPrefix("Discord did not accept that token."))
        XCTAssertTrue(refusal.label.contains("three parts joined by dots"))
        XCTAssertFalse(primary(app).isEnabled, "the same token is not sent twice")
        XCTAssertFalse(element(app, "stepFlowStatusBlock").exists, "the refusal stays on the field, not on a separate screen")
        shot(app, "discord-flow-token-refused")
    }
}
