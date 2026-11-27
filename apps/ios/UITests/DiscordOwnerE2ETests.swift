import XCTest

final class DiscordOwnerE2ETests: BotProfileTestCase {
    private func text(of element: XCUIElement) -> String {
        element.label.isEmpty ? element.value as? String ?? "" : element.label
    }

    private func primary(_ app: XCUIApplication) -> XCUIElement { element(app, "stepFlowPrimary") }

    private func expectTitle(_ app: XCUIApplication, startingWith prefix: String) {
        let heading = element(app, "stepFlowStepTitle")
        waitFor(heading, timeout: 30, "a step title")
        waitUntil(30, "the screen reads \(prefix)") { text(of: heading).hasPrefix(prefix) }
    }

    func testABotThatIsSetUpButOfflineSaysSoAndReconnects() throws {
        let app = signedInApp(extraArguments: ["-hermes-test-discord-wizard", "-hermes-test-discord-offline"])
        openProfile(app, Self.primarySlug)
        element(app, "profileDiscordRow").hit()
        let title = element(app, "discordOfflineTitle")
        waitFor(title, timeout: 30, "the not connected page")
        waitUntil(10, "it says Discord is not connected") { text(of: title) == "Discord is not connected" }
        XCTAssertFalse(element(app, "stepFlowCalmTitle").exists, "the page does not claim a connection")
        shot(app, "discord-page-offline")
        element(app, "discordOfflineAction").hit()
        let ready = element(app, "stepFlowCalmTitle")
        waitFor(ready, timeout: 60, "the connected page")
        waitUntil(30, "it says Discord is connected") { text(of: ready) == "Discord is connected" }
        shot(app, "discord-page-connected")
    }

    func testAnUnknownOwnerIsAskedForTheirDiscordUserIdAndTheWizardFinishes() throws {
        let app = signedInApp(extraArguments: [
            "-hermes-test-discord-wizard", "-hermes-test-discord-app-ready", "-hermes-test-discord-needs-owner",
        ])
        openProfile(app, Self.primarySlug)
        element(app, "profileDiscordRow").hit()
        waitFor(element(app, "stepFlow"), timeout: 30, "the Discord wizard")
        expectTitle(app, startingWith: "Create ")
        primary(app).hit()

        expectTitle(app, startingWith: "Your Discord user id")
        let field = element(app, "stepFlowField-owner_member_id")
        waitFor(field, timeout: 10, "owner field")
        XCTAssertFalse(primary(app).isEnabled, "an id is needed first")
        shot(app, "discord-wizard-owner")
        field.hit()
        field.typeText("123456")
        let hint = element(app, "stepFlowHint-owner_member_id")
        waitFor(hint, timeout: 10, "inline validation")
        XCTAssertEqual(text(of: hint), "That is not a user id. It has 17 to 20 digits. Copy it again.")
        XCTAssertFalse(primary(app).isEnabled)
        shot(app, "discord-wizard-owner-invalid")
        field.typeText("789012345678")
        waitUntil(10, "an 18 digit id is accepted") { primary(app).isEnabled }
        shot(app, "discord-wizard-owner-valid")
        primary(app).hit()

        let ready = element(app, "stepFlowCalmTitle")
        waitFor(ready, timeout: 60, "the ready screen")
        waitUntil(30, "the ready screen says Discord is connected") { text(of: ready) == "Discord is connected" }
        shot(app, "discord-wizard-ready")
    }
}
