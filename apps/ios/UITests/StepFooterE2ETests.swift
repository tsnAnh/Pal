import XCTest

@MainActor
final class StepFooterE2ETests: ConnectAppsTestCase {
    private let token = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"

    #if os(macOS)
    private let minimumHeight: CGFloat = 38
    #else
    private let minimumHeight: CGFloat = 52
    #endif

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openFlow(_ app: XCUIApplication) {
        waitForCatalog(app)
        search(app, "Discord")
        let button = action(app, "discord")
        waitFor(button, timeout: 30, "Discord action")
        button.hit()
        waitFor(element(app, "stepFlow"), timeout: 20, "step flow")
    }

    private func primary(_ app: XCUIApplication) -> XCUIElement {
        let button = element(app, "stepFlowPrimary")
        waitFor(button, timeout: 15, "primary action")
        return button
    }

    func testTheSingleButtonFooterHoldsTheFooterHeight() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        openFlow(app)
        let next = primary(app)
        XCTAssertFalse(element(app, "stepFlowBack").exists, "the first step has no Back")
        XCTAssertGreaterThanOrEqual(next.frame.height, minimumHeight, "the primary is at least the footer height")
        shot(app, "step-footer-single")
    }

    func testBackAndPrimaryShareOneHeightWithAShortAndALongLabelAndTheDisabledState() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        openFlow(app)
        let shortLabel = primary(app).label
        primary(app).hit()
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "developer portal handed to the browser") { opened.label.hasPrefix("https://discord.com/developers/applications") }
        let field = element(app, "stepFlowField-token")
        waitFor(field, timeout: 20, "token field")

        let next = primary(app)
        let back = element(app, "stepFlowBack")
        waitFor(back, timeout: 10, "Back")
        XCTAssertNotEqual(next.label, shortLabel, "the second step carries a longer label")
        XCTAssertFalse(next.isEnabled, "the primary is disabled until the token is pasted")
        XCTAssertGreaterThanOrEqual(back.frame.height, minimumHeight)
        XCTAssertEqual(back.frame.height, next.frame.height, accuracy: 1, "Back and the primary are one height")
        shot(app, "step-footer-disabled")

        field.hit()
        field.typeText(token)
        XCTAssertTrue(next.isEnabled, "the primary enables once the token is in")
        XCTAssertEqual(back.frame.height, next.frame.height, accuracy: 1, "the height does not change with the state")
        shot(app, "step-footer-enabled")
    }
}
