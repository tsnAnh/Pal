import XCTest

@MainActor
final class T3CodeConnectorE2ETests: ConnectAppsTestCase {
    func test1T3CodeIsAnOrdinaryRowWhoseWizardNamesAnUnreachableAddress() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        search(app, "T3 Code")
        let connect = action(app, "t3code")
        waitFor(connect, timeout: 30, "T3 Code row action")
        XCTAssertEqual(connect.label, "Connect")
        connect.tap()

        let flow = app.descendants(matching: .any)["stepFlow"]
        waitFor(flow, timeout: 15, "T3 Code wizard")
        waitLabel(app.staticTexts["stepFlowStepTitle"], contains: "Turn on network access")
        shot(app, "t3code-step-network")
        app.buttons["stepFlowPrimary"].tap()

        let field = app.descendants(matching: .any)["stepFlowField-address"]
        waitFor(field, timeout: 15, "address field")
        XCTAssertFalse(app.buttons["stepFlowPrimary"].isEnabled, "the check waits for an address")
        field.tap()
        field.typeText("127.0.0.1:1")
        app.buttons["stepFlowPrimary"].tap()

        let title = app.descendants(matching: .any)["stepFlowStatusTitle"]
        waitFor(title, timeout: 60, "unreachable status block")
        waitLabel(title, contains: "could not reach T3 Code")
        waitLabel(app.buttons["stepFlowStatusAction"], equals: "Enter the address again")
        shot(app, "t3code-status-unreachable")
    }
}
