import XCTest

@MainActor
final class SetupGuideE2ETests: ConnectAppsTestCase {
    private let googleRedirect = "https://pal.example.test/webapp/google-install/callback"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openGuide(_ app: XCUIApplication, name: String, slug: String, action title: String) -> XCUIElement {
        waitForCatalog(app)
        search(app, name)
        let button = action(app, slug)
        waitFor(button, timeout: 30, "\(name) action")
        XCTAssertEqual(button.label, title)
        button.hit()
        waitFor(element(app, "setupGuide"), timeout: 20, "setup guide")
        return button
    }

    private func expectStep(_ app: XCUIApplication, _ id: String, _ position: String) {
        waitFor(element(app, "setupGuideStep-\(id)"), timeout: 20, "step \(id)")
        XCTAssertTrue(element(app, "setupGuideProgress").label.contains(position), "step \(id) reads \(position)")
    }

    private func next(_ app: XCUIApplication) {
        let button = element(app, "setupGuideNext")
        waitFor(button, timeout: 10, "next")
        button.hit()
    }

    private func enter(_ app: XCUIApplication, _ id: String, _ text: String) {
        let field = element(app, "setupGuideField-\(id)")
        waitFor(field, timeout: 10, "field \(id)")
        field.hit()
        field.typeText(text)
    }

    private func submit(_ app: XCUIApplication) -> XCUIElement {
        let button = element(app, "setupGuideSubmit")
        waitFor(button, timeout: 10, "submit")
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        return button
    }

    private func openedLink(_ app: XCUIApplication, prefix: String) {
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "page handed to the system browser") { opened.label.hasPrefix(prefix) }
    }

    private func rejectOnce(_ app: XCUIApplication, code: String, shotName: String) {
        waitFor(element(app, "setupGuideStatus"), timeout: 20, "check failure")
        element(app, "setupGuideDetails").hit()
        waitFor(element(app, "setupGuideCopyDetails"), timeout: 10, "copy details")
        XCTAssertEqual(element(app, "setupGuideReasonCode").label, code, "details name the reason code")
        shot(app, shotName)
        element(app, "setupGuidePrimary").hit()
        waitFor(element(app, "setupGuideSubmit"), timeout: 20, "paste step again")
    }

    private func returnLoopbackRedirect(_ app: XCUIApplication) {
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
    }

    func test1GoogleResumesAtTheConsoleStepChecksTheClientAndConnects() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let button = openGuide(app, name: "Google Workspace", slug: "google-workspace", action: "Set up")
        expectStep(app, "console", "2 of 4")
        let redirect = element(app, "setupGuideCopy-0Value")
        waitFor(redirect, timeout: 10, "redirect URI")
        XCTAssertEqual(redirect.label, googleRedirect, "the redirect URI is shown exactly")
        element(app, "setupGuideCopy-0Button").hit()
        waitLabel(element(app, "setupGuideCopy-0Button"), contains: "Copied", timeout: 10)
        element(app, "setupGuideLink-0").hit()
        openedLink(app, prefix: "https://console.cloud.google.com/apis/credentials")
        element(app, "setupGuideBack").hit()
        expectStep(app, "address", "1 of 4")
        XCTAssertEqual(element(app, "setupGuideAddressValue").label, "https://pal.example.test", "the public address is shown")
        next(app)
        expectStep(app, "console", "2 of 4")
        next(app)
        expectStep(app, "apis", "3 of 4")
        waitFor(element(app, "setupGuideLink-5"), timeout: 10, "a link for every Google service")
        shot(app, "setup-guide-google-apis")
        next(app)
        expectStep(app, "client", "4 of 4")
        XCTAssertFalse(submit(app).isEnabled, "Check waits for both fields")
        enter(app, "client_id", "wrong")
        waitFor(element(app, "setupGuideHint-client_id"), timeout: 10, "live shape hint")
        XCTAssertTrue(element(app, "setupGuideHint-client_id").label.contains(".apps.googleusercontent.com"))
        element(app, "setupGuideField-client_id").typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        enter(app, "client_id", "fake-client-id.apps.googleusercontent.com")
        enter(app, "client_secret", "rejected-secret-do-not-use")
        waitFor(element(app, "setupGuideShapeOK-client_id"), timeout: 10, "shape accepted")
        XCTAssertTrue(submit(app).isEnabled, "Check is ready with both fields")
        submit(app).hit()
        rejectOnce(app, code: "INVALID_CLIENT", shotName: "setup-guide-google-rejected")
        enter(app, "client_id", "fake-client-id.apps.googleusercontent.com")
        enter(app, "client_secret", "fake-token-do-not-use")
        submit(app).hit()
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after saving")
        openedLink(app, prefix: "https://accounts.google.com/")
        waitLabel(button, contains: "Remove", timeout: 45)
        shot(app, "setup-guide-google-connected")
    }

    func test2GoogleWithoutAPublicAddressOpensTheAddressStep() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-no-public-address"])
        _ = openGuide(app, name: "Google Workspace", slug: "google-workspace", action: "Set up")
        expectStep(app, "address", "1 of 4")
        waitFor(element(app, "setupAddressField"), timeout: 20, "address field")
        XCTAssertFalse(element(app, "setupGuideAddressValue").exists, "no saved address to copy")
        XCTAssertFalse(element(app, "setupGuideCopy-0Value").exists, "no redirect URI without a public address")
        XCTAssertFalse(element(app, "setupAddressSave").isEnabled, "Save waits for an address")
        shot(app, "setup-guide-needs-public-address")
    }

    func test3GitHubChecksTheTokenShapeThenTheTokenAndSavesIt() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let button = openGuide(app, name: "GitHub", slug: "github", action: "Connect")
        expectStep(app, "token_page", "1 of 2")
        XCTAssertEqual(element(app, "setupGuideCopy-0Value").label, "Pal", "the token name is ready to copy")
        element(app, "setupGuideLink-0").hit()
        openedLink(app, prefix: "https://github.com/settings/personal-access-tokens/new")
        next(app)
        expectStep(app, "token", "2 of 2")
        enter(app, "token", "wrong")
        waitFor(element(app, "setupGuideHint-token"), timeout: 10, "live shape hint")
        XCTAssertTrue(element(app, "setupGuideHint-token").label.contains("github_pat_"))
        XCTAssertFalse(submit(app).isEnabled, "Check waits for a token shaped like GitHub's")
        element(app, "setupGuideField-token").typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        enter(app, "token", "github_pat_rejected-do-not-use")
        submit(app).hit()
        rejectOnce(app, code: "INVALID_TOKEN", shotName: "setup-guide-github-rejected")
        enter(app, "token", "github_pat_fake-token-do-not-use")
        XCTAssertFalse(app.staticTexts["github_pat_fake-token-do-not-use"].exists, "the token is never echoed")
        submit(app).hit()
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after saving")
        waitLabel(button, contains: "Update token", timeout: 30)
        shot(app, "setup-guide-github-connected")
    }

    private func guideThroughClient(_ app: XCUIApplication, name: String, slug: String, page: String, authorize: String) {
        let button = openGuide(app, name: name, slug: slug, action: "Set up")
        expectStep(app, "app", "1 of 2")
        let redirect = "https://pal.example.test/webapp/mcp-oauth/callback"
        XCTAssertEqual(element(app, "setupGuideCopy-0Value").label, redirect, "the gateway redirect is shown exactly")
        XCTAssertTrue(element(app, "setupGuideCopy-1Value").label.contains(":read"), "the scopes are ready to copy")
        element(app, "setupGuideLink-0").hit()
        openedLink(app, prefix: page)
        next(app)
        expectStep(app, "client", "2 of 2")
        enter(app, "client_id", "fake-client-id")
        enter(app, "client_secret", "fake-token-do-not-use")
        waitFor(element(app, "setupGuideShapeOK-client_id"), timeout: 10, "shape accepted")
        XCTAssertEqual(submit(app).label, "Save", "no test call, so the action only saves")
        submit(app).hit()
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after saving")
        openedLink(app, prefix: authorize)
        returnLoopbackRedirect(app)
        waitLabel(button, contains: "Remove", timeout: 45)
        shot(app, "setup-guide-\(slug)-connected")
    }

    func test5FigmaGuidesTheAppThenSavesTheClientWithoutATestCall() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        guideThroughClient(
            app, name: "Figma", slug: "figma", page: "https://www.figma.com/developers/apps", authorize: "https://www.figma.com/oauth"
        )
    }

    func test6DropboxGuidesTheAppThenSavesTheClientWithoutATestCall() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        guideThroughClient(
            app, name: "Dropbox", slug: "dropbox", page: "https://www.dropbox.com/developers/console/apps",
            authorize: "https://www.dropbox.com/oauth2/authorize"
        )
    }

    func test8CanvaGuidesTheAppRejectsTheClientThenSavesAndConnects() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let button = openGuide(app, name: "Canva", slug: "canva", action: "Set up")
        expectStep(app, "app", "1 of 2")
        XCTAssertEqual(element(app, "setupGuideCopy-0Value").label, "https://pal.example.test/webapp/mcp-oauth/callback")
        XCTAssertTrue(element(app, "setupGuideCopy-1Value").label.contains(":read"), "the scopes are ready to copy")
        element(app, "setupGuideLink-0").hit()
        openedLink(app, prefix: "https://www.canva.com/developers/apps")
        next(app)
        expectStep(app, "client", "2 of 2")
        enter(app, "client_id", "fake-client-id")
        enter(app, "client_secret", "rejected-secret-do-not-use")
        submit(app).hit()
        rejectOnce(app, code: "INVALID_CLIENT", shotName: "setup-guide-canva-rejected")
        enter(app, "client_id", "fake-client-id")
        enter(app, "client_secret", "fake-token-do-not-use")
        submit(app).hit()
        waitGone(element(app, "setupGuide"), timeout: 30, "guide closes after saving")
        openedLink(app, prefix: "https://www.canva.com/api/oauth/authorize")
        returnLoopbackRedirect(app)
        waitLabel(button, contains: "Remove", timeout: 45)
        shot(app, "setup-guide-canva-connected")
    }

    func test7GoogleRefusesAnIPAddressAndOffersTheFallbacks() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-ip-address"])
        _ = openGuide(app, name: "Google Workspace", slug: "google-workspace", action: "Set up")
        expectStep(app, "address", "1 of 4")
        let title = app.staticTexts["Google refuses this address"]
        waitFor(title, timeout: 20, "address problem title")
        XCTAssertFalse(element(app, "setupGuideAddressValue").exists, "the refused address is not offered for copying")
        element(app, "setupGuideAddressProblemDetails").hit()
        waitFor(element(app, "setupGuideAddressProblemCopyDetails"), timeout: 10, "copy details")
        let details = element(app, "setupGuideAddressProblemReasonCode").label
        XCTAssertTrue(details.contains("IP_HOST") && details.contains("100.101.102.103"), "details name the rule and the host")
        shot(app, "setup-guide-google-ip-address")
        next(app)
        expectStep(app, "console", "2 of 4")
        let fallback = element(app, "setupGuideFallback")
        waitFor(fallback, timeout: 10, "fallback action")
        XCTAssertEqual(fallback.label, "Google rejected the address")
        XCTAssertFalse(element(app, "setupGuideFallbackBody").exists, "the fallback is hidden until tapped")
        fallback.hit()
        waitFor(element(app, "setupGuideFallbackBody"), timeout: 10, "fallback text")
        element(app, "setupGuideFallbackLink-0").hit()
        openedLink(app, prefix: "https://developers.google.com/identity/protocols/oauth2/native-app")
        shot(app, "setup-guide-google-fallback")
    }
}
