import XCTest

@MainActor
final class PublicAddressE2ETests: ConnectAppsTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func reachable(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        waitFor(target, timeout: 20, id)
        for _ in 0..<6 where !target.isHittable { app.swipeUp() }
        return target
    }

    private func replaceAddress(_ app: XCUIApplication, with text: String) {
        let field = reachable(app, "setupAddressField")
        field.hit()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText(text)
    }

    private func openAddressStep(_ app: XCUIApplication) {
        waitForCatalog(app)
        search(app, "Google Workspace")
        let button = action(app, "google-workspace")
        waitFor(button, timeout: 30, "Google Workspace action")
        button.hit()
        waitFor(element(app, "setupGuideStep-address"), timeout: 20, "address step")
    }

    func test1SuggestionSaveAndCheckReportEachOutcome() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-no-public-address"])
        openAddressStep(app)
        XCTAssertFalse(element(app, "setupGuideAddressValue").exists, "nothing is saved yet")
        XCTAssertFalse(reachable(app, "setupAddressSave").isEnabled, "Save waits for an address")
        XCTAssertFalse(element(app, "setupAddressCheck").isEnabled, "Check waits for a saved address")

        replaceAddress(app, with: "http://pal.example.test")
        waitFor(element(app, "setupAddressHint"), timeout: 10, "live validation message")
        XCTAssertTrue(element(app, "setupAddressHint").label.contains("https://"), "the message names the https rule")
        XCTAssertFalse(element(app, "setupAddressSave").isEnabled, "an invalid address cannot be saved")

        waitFor(element(app, "setupAddressSuggestionValue"), timeout: 10, "tailnet suggestion")
        XCTAssertEqual(element(app, "setupAddressSuggestionValue").label, "https://pal.example.test")
        reachable(app, "setupAddressUse").hit()
        waitFor(element(app, "setupAddressOK"), timeout: 10, "shape accepted")
        XCTAssertEqual(element(app, "setupAddressField").value as? String, "https://pal.example.test", "Use this fills the field")
        shot(app, "public-address-suggestion")

        reachable(app, "setupAddressSave").hit()
        waitFor(element(app, "setupGuideAddressValue"), timeout: 30, "saved address")
        XCTAssertEqual(element(app, "setupGuideAddressValue").label, "https://pal.example.test", "the saved address is shown")
        reachable(app, "setupAddressCheck").hit()
        waitFor(app.staticTexts["Address reachable"], timeout: 20, "reachable result")
        shot(app, "public-address-reachable")

        replaceAddress(app, with: "https://offline.example.test")
        reachable(app, "setupAddressSave").hit()
        waitLabel(element(app, "setupGuideAddressValue"), contains: "offline.example.test", timeout: 30)
        reachable(app, "setupAddressCheck").hit()
        waitFor(app.staticTexts["Address not served yet"], timeout: 20, "not served result")
        reachable(app, "setupAddressResultDetails").hit()
        waitFor(element(app, "setupAddressResultCopyDetails"), timeout: 10, "copy details")
        XCTAssertEqual(element(app, "setupAddressResultReasonCode").label, "NOT_SERVED", "details name the outcome")
        shot(app, "public-address-not-served")
    }
}
