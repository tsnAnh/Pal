import XCTest

@MainActor
final class DiscordWizardE2ETests: BotProfileTestCase {
    private let token = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"

    private func openWizard(_ app: XCUIApplication) {
        openProfile(app, Self.primarySlug)
        element(app, "profileDiscordRow").tap()
        waitFor(element(app, "stepFlow"), timeout: 30, "the Discord wizard")
    }

    private func expectTitle(_ app: XCUIApplication, _ title: String) {
        let heading = element(app, "stepFlowStepTitle")
        waitFor(heading, timeout: 30, "a step title")
        waitUntil(30, "the screen reads \(title)") { heading.label == title }
    }

    private func expectReady(_ app: XCUIApplication) {
        let title = element(app, "stepFlowCalmTitle")
        waitFor(title, timeout: 60, "the ready screen")
        waitUntil(30, "the ready screen names the bot in Discord") { title.label.hasSuffix("is in Discord") }
        XCTAssertTrue(element(app, "discordOpen").exists, "Open in Discord is offered")
    }

    private func primary(_ app: XCUIApplication) -> XCUIElement {
        let button = element(app, "stepFlowPrimary")
        waitFor(button, timeout: 15, "primary action")
        return button
    }

    func testTheFirstBotMakesThePalAppPicksAServerAndEndsOnTheReadyScreen() throws {
        let app = signedInApp(extraArguments: ["-hermes-test-discord-wizard"])
        openWizard(app)
        shot(app, "discord-wizard-start")

        primary(app).tap()
        expectTitle(app, "Paste the Pal app token")
        let field = element(app, "stepFlowField-token")
        waitFor(field, timeout: 10, "token field")
        field.tap()
        field.typeText(token)
        XCTAssertFalse(app.staticTexts[token].exists, "the token is never echoed")
        shot(app, "discord-wizard-token")
        primary(app).tap()

        expectTitle(app, "Pick the server")
        XCTAssertFalse(primary(app).isEnabled, "one server has to be picked first")
        element(app, "stepFlowSwitch-new").tap()
        shot(app, "discord-wizard-server")
        primary(app).tap()

        expectTitle(app, "Invite Pal to your server")
        shot(app, "discord-wizard-invite")
        primary(app).tap()

        expectReady(app)
        shot(app, "discord-wizard-ready")
    }

    func testTheNextBotNeedsOneTap() throws {
        let app = signedInApp(extraArguments: ["-hermes-test-discord-wizard", "-hermes-test-discord-app-ready"])
        openWizard(app)
        let heading = element(app, "stepFlowStepTitle")
        waitFor(heading, timeout: 30, "the channel step")
        waitUntil(30, "the first screen is the channel step") { heading.label.hasPrefix("Create ") }
        shot(app, "discord-wizard-second-bot")
        primary(app).tap()
        expectReady(app)
    }
}
