import XCTest

@MainActor
final class OAuthClientE2ETests: ConnectAppsTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func enterClient(_ app: XCUIApplication, redirect: String) {
        let sheet = element(app, "oauthClientSetup")
        waitFor(sheet, timeout: 20, "set up sheet")
        let address = element(app, "oauthClientRedirect")
        waitFor(address, timeout: 20, "redirect URL")
        XCTAssertEqual(address.label, redirect, "the redirect URL is shown exactly")
        waitFor(element(app, "oauthClientCopyRedirect"), timeout: 5, "copy button")
        let save = element(app, "oauthClientSave")
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertFalse(save.isEnabled, "Save waits for both fields")
        element(app, "oauthClientID").hit()
        element(app, "oauthClientID").typeText("fake-client-id")
        element(app, "oauthClientSecret").hit()
        element(app, "oauthClientSecret").typeText("fake-token-do-not-use")
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled, "Save is ready with both fields")
        shot(app, "oauth-client-setup")
        save.hit()
        waitGone(sheet, timeout: 20, "set up sheet closes after saving")
    }

    private func openedLink(_ app: XCUIApplication, prefix: String) {
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "sign-in page handed to the system browser") { opened.label.hasPrefix(prefix) }
    }

    func test7GoogleGoesFromNeedsSetupToConnectedThroughTheGatewayPage() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        waitForCatalog(app)
        search(app, "Google Workspace")
        let button = action(app, "google-workspace")
        waitFor(button, timeout: 30, "Google Workspace action")
        XCTAssertEqual(button.label, "Set up")
        button.hit()
        enterClient(app, redirect: "https://pal.example.test/webapp/google-install/callback")
        waitLabel(button, contains: "Connect")
        button.hit()
        openedLink(app, prefix: "https://accounts.google.com/")
        waitLabel(button, contains: "Remove", timeout: 45)
        shot(app, "oauth-client-google-connected")
    }

    func test8GoogleSetUpWithoutAPublicAddressShowsTheGuidedStatus() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-no-public-address"])
        waitForCatalog(app)
        search(app, "Google Workspace")
        let button = action(app, "google-workspace")
        waitFor(button, timeout: 30, "Google Workspace action")
        button.hit()
        let status = element(app, "oauthClientStatus")
        waitFor(status, timeout: 20, "status block")
        let title = app.staticTexts["Public address needed"]
        let primary = element(app, "oauthClientPrimary")
        waitFor(title, timeout: 10, "status title")
        waitFor(primary, timeout: 10, "try again action")
        XCTAssertGreaterThan(primary.frame.minY, title.frame.maxY, "the action is below the text")
        XCTAssertLessThanOrEqual(primary.frame.minY - title.frame.maxY, 160, "the action sits right under the text")
        XCTAssertLessThanOrEqual(status.frame.width, 440, "the block keeps a readable width")
        XCTAssertFalse(element(app, "oauthClientRedirect").exists, "no redirect field without a public address")
        element(app, "oauthClientDetails").hit()
        waitFor(element(app, "oauthClientCopyDetails"), timeout: 10, "copy button")
        XCTAssertEqual(element(app, "oauthClientReasonCode").label, "NEEDS_PUBLIC_URL", "details name the reason code")
        XCTAssertTrue(app.staticTexts["Set this gateway's public address first."].exists)
        shot(app, "oauth-client-needs-public-address")
    }
}
