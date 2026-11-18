import XCTest

@MainActor
final class SetupResumeE2ETests: ConnectAppsTestCase {
    private var otherDevice: String {
        #if os(macOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }

    private func launchWithAnotherDevicesProgress() -> XCUIApplication {
        launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-setup-progress-other-device"])
    }

    func test1TheListOffersWhatAnotherDeviceStartedAndTheFlowOpensAtThatStep() throws {
        let app = launchWithAnotherDevicesProgress()
        let setup = OwnerSetupDriver(test: self, app: app)
        waitForCatalog(app)
        waitFor(setup.el("setupResumeBanner"), timeout: 30, "continue banner")
        waitLabel(setup.el("setupResumeBannerTitle"), equals: "Continue Google Workspace", timeout: 10)
        waitLabel(setup.el("setupResumeBannerDetail"), equals: "Started on your \(otherDevice)", timeout: 10)
        XCTAssertEqual(setup.el("setupResumeBannerAction").label, "Continue")
        shot(app, "setup-resume-list")
        setup.el("setupResumeBannerAction").hit()
        waitFor(setup.el("stepFlow"), timeout: 30, "step flow")
        setup.expectStep("client", "Paste the two values Google shows", number: 4, of: 5)
        XCTAssertFalse(setup.el("stepFlowIntro").exists, "a step done once is never asked again")
        waitLabel(setup.el("stepFlowContinuedTitle"), equals: "Continued from your \(otherDevice)", timeout: 10)
        waitLabel(setup.el("stepFlowContinuedDetail"), equals: "Steps 1 to 3 are already done", timeout: 10)
        setup.expectPrimary(enabled: false, "Check and save waits for both fields")
        shot(app, "setup-resume-flow")
    }

    func test2ProgressMadeOnThisDeviceResumesWithoutAnyBanner() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let setup = OwnerSetupDriver(test: self, app: app)
        let button = setup.open("Google Workspace", slug: "google-workspace")
        setup.expectIntro("Set up Google Workspace", rows: 5)
        setup.primary("Start")
        setup.expectStep("console", "Open Google Cloud", number: 1, of: 5)
        setup.el("stepFlowSkip").hit()
        setup.expectStep("client", "Paste the two values Google shows", number: 4, of: 5)
        setup.close()
        waitGone(setup.el("setupResumeBanner"), timeout: 10, "no banner for this device's own progress")
        button.hit()
        waitFor(setup.el("stepFlow"), timeout: 30, "step flow")
        setup.expectStep("client", "Paste the two values Google shows", number: 4, of: 5)
        XCTAssertFalse(setup.el("stepFlowContinued").exists, "no continuation notice for this device's own progress")
    }
}
