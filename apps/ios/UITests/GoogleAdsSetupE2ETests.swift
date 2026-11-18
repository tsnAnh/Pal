import XCTest

@MainActor
final class GoogleAdsSetupE2ETests: ConnectAppsTestCase {
    private let rows = ["api", "explorer", "consent", "signin", "manager"]
    private let sevenDays = "While the app is in Testing mode, Google ends the sign-in after 7 days."
    private let overview = "https://console.cloud.google.com/apis/api/googleads.googleapis.com/overview"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openFlow(_ app: XCUIApplication) -> XCUIElement {
        waitForCatalog(app)
        search(app, "Google Ads")
        let button = action(app, "google-ads")
        waitFor(button, timeout: 30, "Google Ads action")
        button.hit()
        waitFor(element(app, "stepFlow"), timeout: 20, "step flow")
        return button
    }

    private func expectStep(_ app: XCUIApplication, _ row: Int, _ title: String) {
        let heading = element(app, "stepFlowStepTitle")
        waitFor(heading, timeout: 30, "step \(row)")
        waitUntil(20, "step \(row) reads \(title)") { heading.label == title }
        let position = element(app, "stepFlowPosition")
        if position.exists {
            XCTAssertEqual(position.label, "Step \(row) of 5", "the segments say where you are")
        } else {
            XCTAssertTrue(element(app, "stepFlowRow-\(rows[row - 1])").exists, "the checklist lists step \(row)")
        }
    }

    private func primary(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let button = element(app, "stepFlowPrimary")
        waitFor(button, timeout: 15, "primary action")
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertEqual(button.label, title)
        return button
    }

    private func expectOpened(_ app: XCUIApplication, _ prefix: String) {
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "\(prefix) handed to the browser") { opened.label.hasPrefix(prefix) }
    }

    private func walkToTheManagerStep(_ app: XCUIApplication) {
        expectStep(app, 1, "Turn on the Google Ads API")
        primary(app, "Open Google Cloud").hit()
        expectOpened(app, "https://console.cloud.google.com/apis/library/googleads.googleapis.com")

        expectStep(app, 2, "Apply for Explorer access")
        XCTAssertTrue(element(app, "stepFlowStepBody").label.contains("The review is automatic and takes minutes."))
        primary(app, "Open Google Cloud").hit()
        expectOpened(app, overview)

        expectStep(app, 3, "Add Google Ads to your Google sign-in")
        XCTAssertTrue(element(app, "stepFlowStepBody").label.contains(sevenDays), "the Testing-mode expiry reads as it does for Google Workspace")
        XCTAssertTrue(element(app, "stepFlowNote").exists, "publishing the app is a later option, not a step")
        primary(app, "Open the consent screen").hit()
        expectOpened(app, "https://console.cloud.google.com/apis/credentials/consent")

        expectStep(app, 4, "Sign in to Google")
        primary(app, "Sign in with Google").hit()
        expectOpened(app, "https://accounts.google.com/o/oauth2/v2/auth")
        waitFor(element(app, "stepFlowWaiting"), timeout: 15, "waiting for the browser")
        expectStep(app, 5, "Add your manager account")
    }

    func testGoogleAdsRunsTheStepsSavesTheManagerIdAsDigitsAndConnects() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let button = openFlow(app)
        shot(app, "google-ads-flow-step-1")
        walkToTheManagerStep(app)
        shot(app, "google-ads-flow-manager")

        XCTAssertFalse(primary(app, "Save").isEnabled, "an empty field is skipped, not saved")
        XCTAssertEqual(element(app, "stepFlowSkip").label, "Skip")
        let field = element(app, "stepFlowField-manager")
        waitFor(field, timeout: 10, "manager account field")
        field.hit()
        field.typeText("abc")
        primary(app, "Save").hit()
        let refusal = element(app, "stepFlowRefusal")
        waitFor(refusal, timeout: 15, "refusal on the field")
        XCTAssertTrue(refusal.label.hasPrefix("That manager account ID does not look right."))
        XCTAssertFalse(element(app, "stepFlowStatusBlock").exists, "the refusal stays on the field")
        shot(app, "google-ads-flow-manager-refused")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        field.typeText("123-456-7890")
        primary(app, "Save").hit()

        let heading = element(app, "stepFlowStepTitle")
        waitUntil(30, "check step") { heading.label == "Check your Google Ads access" }
        primary(app, "Check access").hit()
        waitFor(element(app, "stepFlowSuccess"), timeout: 60, "connected screen")
        shot(app, "google-ads-flow-connected")
        primary(app, "Done").hit()
        waitGone(element(app, "stepFlow"), timeout: 30, "the flow closes")
        waitLabel(button, contains: "Connected", timeout: 30)
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Manager account 1234567890.")).firstMatch
        waitFor(summary, timeout: 30, "the saved manager account id is digits only")
    }

    func testSkippingTheManagerAccountAndExplorerAccessNeededGoesBackToTheGooglePage() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-google-ads-explorer"])
        let button = openFlow(app)
        walkToTheManagerStep(app)
        element(app, "stepFlowSkip").hit()

        let heading = element(app, "stepFlowStepTitle")
        waitUntil(30, "check step") { heading.label == "Check your Google Ads access" }
        primary(app, "Check access").hit()

        let title = element(app, "stepFlowStatusTitle")
        waitFor(title, timeout: 60, "explorer status")
        XCTAssertEqual(title.label, "Apply for Explorer access")
        XCTAssertTrue(element(app, "stepFlowStatusReason").label.contains("automatic and takes minutes"))
        shot(app, "google-ads-flow-explorer-needed")
        let reopen = element(app, "stepFlowStatusAction")
        XCTAssertEqual(reopen.label, "Open Google Cloud")
        reopen.hit()
        expectOpened(app, overview)
        waitGone(element(app, "stepFlowStatusBlock"), timeout: 15, "the status closes after reopening the page")

        primary(app, "Check access").hit()
        waitFor(element(app, "stepFlowSuccess"), timeout: 60, "connected screen")
        primary(app, "Done").hit()
        waitGone(element(app, "stepFlow"), timeout: 30, "the flow closes")
        waitLabel(button, contains: "Connected", timeout: 30)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Manager account")).firstMatch.exists)
    }
}
