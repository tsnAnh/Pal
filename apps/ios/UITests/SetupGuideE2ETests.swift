import XCTest

@MainActor
final class SetupGuideE2ETests: ConnectAppsTestCase {
    private let googleRedirect = "https://pal.example.test/webapp/google-install/callback"
    private let clientID = "fake-client-id.apps.googleusercontent.com"
    private let goodSecret = "fake-token-do-not-use"
    private let badSecret = "rejected-secret-do-not-use"

    private func googleSetup(_ app: XCUIApplication) -> (OwnerSetupDriver, XCUIElement) {
        let setup = OwnerSetupDriver(test: self, app: app)
        return (setup, setup.open("Google Workspace", slug: "google-workspace"))
    }

    private func startGoogle(_ setup: OwnerSetupDriver) {
        setup.expectIntro("Set up Google Workspace", rows: 5)
        XCTAssertTrue(setup.el("stepFlowIntroYouDo").label.contains("OAuth client in Google Cloud"), "the intro says what you do")
        XCTAssertTrue(setup.el("stepFlowIntroPalDoes").label.contains("checks your values"), "the intro says what Pal does")
        shot(setup.app, "owner-setup-google-intro")
        setup.primary("Start")
        setup.expectStep("console", "Open Google Cloud", number: 1, of: 5)
        XCTAssertTrue(setup.el("stepFlowNote").exists, "the account note shows")
        XCTAssertFalse(setup.el("stepFlowBack").exists, "no way back to the intro")
    }

    private func enterGoogleClient(_ setup: OwnerSetupDriver) {
        setup.expectPrimary(enabled: false, "Check and save waits for both fields")
        setup.enter("client_id", "wrong")
        setup.expectHint("client_id", contains: ".apps.googleusercontent.com")
        setup.expectPrimary(enabled: false, "a wrong id shape keeps Check and save off")
        setup.clear("client_id", removing: "wrong")
        setup.enter("client_id", clientID)
        setup.enter("client_secret", badSecret)
        setup.expectValid("client_id")
        setup.expectValid("client_secret")
        setup.expectPrimary(enabled: true, "Check and save is ready with both fields")
        setup.primary("Check and save")
    }

    func test1GoogleOpenStepOpensTheConsoleAndSkipLandsOnThePasteStep() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let (setup, _) = googleSetup(app)
        startGoogle(setup)
        XCTAssertEqual(setup.el("stepFlowSkip").label, "I already have one")
        XCTAssertEqual(setup.el("stepFlowPrimary").label, "Open Google Cloud")
        shot(app, "owner-setup-google-open")
        setup.el("stepFlowSkip").hit()
        setup.expectStep("client", "Paste the two values Google shows", number: 4, of: 5)
        setup.expectPrimary(enabled: false, "Check and save waits for both fields")
        XCTAssertTrue(setup.el("stepFlowBack").exists, "the flow can go back from the paste step")
        shot(app, "owner-setup-google-skipped")
    }

    private func walkGoogleToTheClientStep(_ setup: OwnerSetupDriver) {
        setup.primary("Open Google Cloud")
        setup.expectOpened("https://console.cloud.google.com/apis/credentials")
        setup.expectStep("console-copy", "Paste this address into Google", number: 2, of: 5)
        XCTAssertEqual(setup.el("stepFlowStepBody").label, "Under Authorized redirect URIs, add:")
        setup.expectCopy(0, equals: googleRedirect)
        waitFor(setup.el("ownerSetupAddressReachable"), timeout: 20, "reachability note")
        shot(setup.app, "owner-setup-google-redirect")
        setup.el("stepFlowBack").hit()
        setup.expectStep("console", "Open Google Cloud", number: 1, of: 5)
        setup.primary("Open Google Cloud")
        setup.expectStep("console-copy", "Paste this address into Google", number: 2, of: 5)
        setup.primary("Next")
        setup.expectStep("apis", "Turn on the Google services", number: 3, of: 5)
        waitFor(setup.el("stepFlowLink-5"), timeout: 10, "a link for every Google service")
        XCTAssertEqual(setup.el("stepFlowLink-0").label, "Gmail")
        setup.reveal("stepFlowLink-0").hit()
        setup.expectOpened("https://console.cloud.google.com/apis/library/gmail.googleapis.com")
        shot(setup.app, "owner-setup-google-services")
        setup.primary("Next")
        setup.expectStep("client", "Paste the two values Google shows", number: 4, of: 5)
    }

    func test2GoogleGuidesTheRedirectAndServicesThenChecksTheClientAndConnects() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let (setup, button) = googleSetup(app)
        startGoogle(setup)
        walkGoogleToTheClientStep(setup)
        enterGoogleClient(setup)
        setup.expectRejected(
            code: "INVALID_CLIENT", title: "Google Workspace did not accept that client", action: "Edit client",
            shot: "owner-setup-google-rejected"
        )
        XCTAssertEqual(setup.el("stepFlowField-client_id").value as? String, clientID, "the id is still there to edit")
        setup.clear("client_secret", removing: badSecret)
        setup.enter("client_secret", goodSecret)
        setup.primary("Check and save")

        setup.expectStep("signin", "Sign in to Google", number: 5, of: 5)
        XCTAssertTrue(setup.el("ownerSetupReplace").exists && setup.el("ownerSetupRemove").exists, "the saved client can be replaced or removed")
        shot(app, "owner-setup-google-signin")
        setup.primary("Sign in with Google")
        setup.expectWaiting("Waiting for Google")
        shot(app, "owner-setup-google-waiting")
        setup.expectOpened("https://accounts.google.com/")
        setup.expectConnected("Google Workspace is connected")
        shot(app, "owner-setup-google-connected")
        setup.finish(button, reads: "Connected")
    }

    func test3GitHubChecksTheTokenShapeThenTheTokenAndSavesIt() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let setup = OwnerSetupDriver(test: self, app: app)
        let button = setup.open("GitHub", slug: "github")
        setup.expectIntro("Set up GitHub", rows: 3)
        shot(app, "owner-setup-github-intro")
        setup.primary("Start")

        setup.expectStep("token_page", "Open GitHub token page", number: 1, of: 3)
        XCTAssertEqual(setup.el("stepFlowSkip").label, "I already have one")
        setup.primary("Open GitHub token page")
        setup.expectOpened("https://github.com/settings/personal-access-tokens/new")
        setup.expectStep("token_page-copy", "Pick access", number: 2, of: 3)
        setup.expectCopy(0, equals: "Pal")
        shot(app, "owner-setup-github-access")
        setup.primary("Next")

        setup.expectStep("token", "Paste your token", number: 3, of: 3)
        setup.expectPrimary(enabled: false, "Check and save waits for a token")
        setup.enter("token", "wrong")
        setup.expectHint("token", contains: "github_pat_")
        setup.expectPrimary(enabled: false, "Check and save waits for a token shaped like GitHub's")
        setup.clear("token", removing: "wrong")
        let rejected = "github_pat_rejected-do-not-use"
        setup.enter("token", rejected)
        setup.primary("Check and save")
        setup.expectRejected(
            code: "INVALID_TOKEN", title: "GitHub did not accept that token", action: "Edit token", shot: "owner-setup-github-rejected"
        )
        let accepted = "github_pat_fake-token-do-not-use"
        setup.clear("token", removing: rejected)
        setup.enter("token", accepted)
        XCTAssertFalse(app.staticTexts[accepted].exists, "the token is never echoed")
        shot(app, "owner-setup-github-token")
        setup.primary("Check and save")

        setup.expectConnected("GitHub is connected")
        shot(app, "owner-setup-github-connected")
        setup.finish(button, reads: "Update token", exact: false)
    }
}
