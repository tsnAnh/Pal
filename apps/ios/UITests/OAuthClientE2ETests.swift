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

    func test6AsanaGoesFromNeedsSetupToConnectedAndBack() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        waitForCatalog(app)
        search(app, "Asana")
        let button = action(app, "asana")
        waitFor(button, timeout: 30, "Asana action")
        XCTAssertEqual(button.label, "Set up")
        button.hit()
        enterClient(app, redirect: "http://localhost:27890/callback")
        waitLabel(button, contains: "Connect")
        button.hit()
        openedLink(app, prefix: "https://app.asana.com/")
        let state = "state=scripted-state"
        #if os(macOS)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:27890/callback?code=fake-token-do-not-use&\(state)")!)
        request.setValue("localhost:27890", forHTTPHeaderField: "Host")
        let returned = expectation(description: "redirect delivered")
        URLSession.shared.dataTask(with: request) { _, _, _ in returned.fulfill() }.resume()
        wait(for: [returned], timeout: 15)
        #else
        let paste = element(app, "otherConnectorPaste")
        waitFor(paste, timeout: 20, "paste sheet")
        let field = element(app, "other-paste-field")
        field.hit()
        field.typeText("http://localhost:27890/callback?code=fake-token-do-not-use&\(state)")
        element(app, "other-paste-submit").hit()
        waitGone(paste, timeout: 20, "paste sheet closes")
        #endif
        waitLabel(button, contains: "Remove")
        shot(app, "oauth-client-asana-connected")
        button.hit()
        let confirm = app.buttons["Disconnect"]
        waitFor(confirm, timeout: 10, "remove confirmation")
        confirm.hit()
        waitLabel(button, contains: "Connect")
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
