import XCTest

@MainActor
final class PublicAddressE2ETests: ConnectAppsTestCase {
    private let addressTitle = "Your Pal's web address"
    private let noAddress = ["-hermes-test-oauth-client", "-hermes-test-oauth-client-no-public-address"]

    private func redirect(_ address: String) -> String {
        "\(address)/webapp/google-install/callback"
    }

    private func openAddressStep(_ app: XCUIApplication) -> OwnerSetupDriver {
        let setup = OwnerSetupDriver(test: self, app: app)
        _ = setup.open("Google Workspace", slug: "google-workspace")
        setup.expectIntro("Set up Google Workspace", rows: 6)
        setup.primary("Start")
        setup.expectStep("address", addressTitle, number: 1, of: 6)
        return setup
    }

    private func saveAddress(_ setup: OwnerSetupDriver, _ address: String) {
        setup.enter("address", address)
        setup.expectValid("address")
        setup.primary("Check and save")
        setup.expectStep("console", "Open Google Cloud", number: 2, of: 6)
    }

    private func openRedirectStep(_ setup: OwnerSetupDriver) {
        setup.primary("Open Google Cloud")
        setup.expectOpened("https://console.cloud.google.com/apis/credentials")
        setup.expectStep("console-copy", "Paste this address into Google", number: 3, of: 6)
    }

    func test1AddressStepValidatesLiveRefusesAnIPAddressAndSavesTheRedirectBase() throws {
        let app = launchConnectApps(extraArguments: noAddress)
        let setup = openAddressStep(app)
        XCTAssertEqual(setup.el("stepFlowStepBody").label, "Google sends you back to your Pal after you sign in.")
        XCTAssertFalse(setup.el("stepFlowBack").exists, "no way back from the first step")
        XCTAssertFalse(setup.el("stepFlowCopy-0").exists, "no redirect address without a public address")
        setup.expectPrimary(enabled: false, "Check and save waits for an address")
        shot(app, "owner-setup-google-address")

        setup.enter("address", "http://pal.example.test")
        setup.expectHint("address", contains: "https://")
        setup.expectPrimary(enabled: false, "an address without https cannot be saved")
        setup.clear("address", removing: "http://pal.example.test")

        let numeric = "https://203.0.113.9"
        setup.enter("address", numeric)
        setup.expectValid("address")
        setup.primary("Check and save")
        setup.expectRejected(
            code: "invalid_token", title: "That address was not accepted", action: "Edit address",
            reason: "Use a domain name, not an IP address.", shot: "owner-setup-google-address-refused"
        )
        XCTAssertEqual(setup.el("stepFlowField-address").value as? String, numeric, "the address is still there to edit")
        setup.clear("address", removing: numeric)

        saveAddress(setup, "https://pal.example.test")
        openRedirectStep(setup)
        setup.expectCopy(0, equals: redirect("https://pal.example.test"))
        waitFor(setup.el("ownerSetupAddressReachable"), timeout: 20, "reachability note")
        XCTAssertFalse(setup.el("ownerSetupAddressBlock").exists, "a reachable address shows no problem")
        shot(app, "owner-setup-google-address-reachable")
    }

    func test2AnAddressPalDoesNotServeShowsTheReasonAndCanBeFixed() throws {
        let app = launchConnectApps(extraArguments: noAddress)
        let setup = openAddressStep(app)
        let offline = "https://offline.example.test"
        saveAddress(setup, offline)
        openRedirectStep(setup)
        setup.expectCopy(0, equals: redirect(offline))

        waitFor(setup.el("ownerSetupAddressBlock"), timeout: 20, "address problem")
        waitLabel(setup.el("ownerSetupAddressTitle"), equals: "Pal could not reach this address", timeout: 10)
        waitLabel(setup.el("ownerSetupAddressReason"), equals: "Your Pal is not serving web sign-in on this address yet.", timeout: 10)
        XCTAssertEqual(setup.el("ownerSetupAddressAction").label, "Check again")
        XCTAssertFalse(setup.el("ownerSetupAddressReachable").exists, "an unserved address is not reported as reachable")
        setup.reveal("ownerSetupAddressDetails").hit()
        waitFor(setup.el("ownerSetupAddressCopyDetails"), timeout: 10, "copy details")
        waitLabel(setup.el("ownerSetupAddressDetailsText"), contains: "code: NOT_SERVED", timeout: 10)
        shot(app, "owner-setup-google-address-not-served")

        setup.reveal("ownerSetupAddressAction").hit()
        waitFor(setup.el("ownerSetupAddressBlock"), timeout: 20, "the check runs again and still fails")

        setup.el("stepFlowBack").hit()
        setup.expectStep("console", "Open Google Cloud", number: 2, of: 6)
        setup.el("stepFlowBack").hit()
        setup.expectStep("address", addressTitle, number: 1, of: 6)
        saveAddress(setup, "https://pal.example.test")
        openRedirectStep(setup)
        setup.expectCopy(0, equals: redirect("https://pal.example.test"))
        waitFor(setup.el("ownerSetupAddressReachable"), timeout: 20, "reachability note after the fix")
        waitGone(setup.el("ownerSetupAddressBlock"), timeout: 10, "the problem clears")
        shot(app, "owner-setup-google-address-fixed")
    }

    func test3GoogleNamesTheIPAddressRuleWithoutOfferingTheAddress() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-ip-address"])
        let setup = openAddressStep(app)
        let body = setup.el("stepFlowStepBody")
        waitLabel(body, contains: "The saved address is an IP address; use a domain name.", timeout: 10)
        XCTAssertTrue(body.label.hasPrefix("Google sends you back to your Pal after you sign in."), "the rule follows the step's own text")
        XCTAssertFalse(setup.el("stepFlowCopy-0").exists, "the refused address is not offered for copying")
        let refusedHost = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "100.101.102.103"))
        XCTAssertFalse(refusedHost.firstMatch.exists, "the refused address is not shown")
        setup.expectPrimary(enabled: false, "Check and save waits for a new address")
        shot(app, "owner-setup-google-ip-address")
    }
}
