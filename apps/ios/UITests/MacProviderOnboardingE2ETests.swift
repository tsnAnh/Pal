#if os(macOS)
import XCTest

@MainActor
final class MacProviderOnboardingE2ETests: BotProfileTestCase {
    private static let argument = "-hermes-test-provider-onboarding"
    private static let claudeMissingArgument = "-hermes-test-provider-onboarding-claude-missing"
    private static let claudeID = "claude-subscription-directsdk-experimental"
    private static let wrongKey = "sk-test-wrong-0001"
    private static let rightKey = "sk-test-right-0001"
    private static let slowKey = "sk-test-slow-0001"
    private static let offlineKey = "sk-test-offline-0001"
    private static let wrongKeyReason = "The key was rejected. Check it and try again."

    private func launchStep(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(extraArguments: [Self.argument] + extraArguments)
        waitFor(element(app, "localEngineProviders"), timeout: 30, "provider step")
        waitFor(element(app, "localEngineProvider-anthropic"), timeout: 30, "provider rows")
        return app
    }

    private func providerRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        element(app, "localEngineProvider-\(id)")
    }

    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        let list = element(app, "localEngineProviders").scrollViews.firstMatch
        for _ in 0..<12 {
            if target.exists && target.isHittable { return }
            list.scroll(byDeltaX: 0, deltaY: -250)
        }
        XCTFail("could not scroll to \(target)\n" + app.debugDescription)
    }

    private func openProvider(_ app: XCUIApplication, _ id: String, action: String) {
        let button = element(app, "localEngineProvider-\(id)-action")
        reveal(app, button)
        XCTAssertEqual(button.label, action, "\(id) offers \(action)")
        button.hit()
    }

    private func submitKey(_ app: XCUIApplication, _ key: String) {
        let field = element(app, "providerKeyField")
        waitFor(field, timeout: 15, "key field")
        field.hit()
        field.typeText(key)
        let next = element(app, "providerKeyContinue")
        waitUntil(10, "Continue enables once a key is typed") { next.isEnabled }
        next.hit()
        waitFor(element(app, "providerTest"), timeout: 15, "test screen")
    }

    private func runTest(_ app: XCUIApplication) {
        let test = element(app, "providerTestConnection")
        waitFor(test, timeout: 20, "Test connection")
        waitUntil(20, "Test connection enables once the model list loads") { test.isEnabled }
        test.hit()
    }

    private func testState(_ app: XCUIApplication) -> String {
        (element(app, "providerTestState").value as? String) ?? ""
    }

    private func waitForState(_ app: XCUIApplication, _ slug: String, timeout: TimeInterval = 20) {
        waitUntil(timeout, "the test reaches \(slug), not \(testState(app))") { testState(app) == slug }
    }

    func testTheChoiceListsSubscriptionsThenKeysThenLocalInOrder() throws {
        let app = launchStep()
        let order = [
            "providerGroupSubscriptions", "localEngineProvider-\(Self.claudeID)", "localEngineProvider-openai-codex",
            "localEngineProvider-nous", "providerGroupKeys", "localEngineProvider-anthropic", "localEngineProvider-openrouter",
            "localEngineProvider-gemini", "localEngineProvidersMore", "providerGroupLocal", "localEngineProvider-lmstudio",
        ]
        var above: XCUIElement?
        for id in order {
            let current = element(app, id)
            reveal(app, current)
            if let above, above.exists {
                XCTAssertLessThan(above.frame.minY, current.frame.minY, "\(id) sits below the row before it")
            }
            above = current
        }
        XCTAssertEqual(element(app, "localEngineProvider-\(Self.claudeID)-tag").label, "Experimental")
        XCTAssertFalse(element(app, "localEngineProvidersContinue").isEnabled, "nothing is connected yet, so Continue waits")
        shot(app, "provider-choice")
    }

    func testTheRowsOfferTheirOwnAction() throws {
        let app = launchStep()
        for (id, action) in [(Self.claudeID, "Set up"), ("openai-codex", "Sign in"), ("anthropic", "Add key"), ("lmstudio", "Set up")] {
            let button = element(app, "localEngineProvider-\(id)-action")
            reveal(app, button)
            XCTAssertEqual(button.label, action, "\(id) offers \(action)")
        }
    }

    func testAWrongKeyFailsWithTheGatewayReasonAndTheRightKeyPassesAndSaves() throws {
        let app = launchStep()
        openProvider(app, "anthropic", action: "Add key")
        submitKey(app, Self.wrongKey)
        runTest(app)
        waitForState(app, "failed")
        let detail = element(app, "providerTestStateDetail")
        waitFor(detail, timeout: 10, "failure reason")
        XCTAssertEqual(detail.label, Self.wrongKeyReason, "the reason comes from the gateway")
        XCTAssertTrue(element(app, "providerTestRetry").exists, "a failed test offers Retry")
        XCTAssertTrue(element(app, "providerTestChangeKey").exists, "a rejected key offers Change key")
        XCTAssertFalse(element(app, "providerTestSaveAndContinue").exists, "a failed test cannot be saved")
        shot(app, "provider-test-failed")

        element(app, "providerTestChangeKey").hit()
        submitKey(app, Self.rightKey)
        runTest(app)
        waitForState(app, "passed")
        let save = element(app, "providerTestSaveAndContinue")
        waitFor(save, timeout: 10, "Save and continue")
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(element(app, "providerTestAgain").exists)
        XCTAssertFalse(element(app, "providerTestRetry").exists)
        XCTAssertFalse(element(app, "providerTestChangeKey").exists)
        XCTAssertTrue(element(app, "providerTestStateDetail").label.contains("1.4 s"), "the latency comes from the gateway")
        shot(app, "provider-test-passed")

        save.hit()
        waitGone(element(app, "localEngineSetupPanel"), timeout: 20, "the step closes after saving")
    }

    func testAnOfflineKeyShowsNoInternetAndCannotBeSaved() throws {
        let app = launchStep()
        openProvider(app, "openrouter", action: "Add key")
        submitKey(app, Self.offlineKey)
        runTest(app)
        waitForState(app, "offline")
        XCTAssertEqual(element(app, "providerTestStateTitle").label, "No internet")
        XCTAssertTrue(element(app, "providerTestRetry").exists)
        XCTAssertFalse(element(app, "providerTestSaveAndContinue").exists)
        shot(app, "provider-test-offline")
    }

    func testASlowTestShowsStillWaitingThenPasses() throws {
        let app = launchStep()
        openProvider(app, "gemini", action: "Add key")
        submitKey(app, Self.slowKey)
        runTest(app)
        waitForState(app, "slow", timeout: 25)
        XCTAssertTrue(element(app, "providerTestCancel").exists, "a running test can be cancelled")
        XCTAssertFalse(element(app, "providerTestSaveAndContinue").exists)
        shot(app, "provider-test-slow")
        waitForState(app, "passed", timeout: 20)
        XCTAssertTrue(element(app, "providerTestSaveAndContinue").exists)
    }

    func testClaudeDirectSdkNotFoundOffersCheckAgainOnly() throws {
        let app = launchStep([Self.claudeMissingArgument])
        openProvider(app, Self.claudeID, action: "Set up")
        waitFor(element(app, "providerClaude"), timeout: 15, "Claude screen")
        let headline = element(app, "providerHeroHeadline")
        waitUntil(15, "Claude Code is reported missing") { headline.exists && headline.label == "Claude Code was not found" }
        XCTAssertTrue(element(app, "providerClaudeCheckAgain").exists)
        XCTAssertFalse(element(app, "providerClaudeContinue").exists)
        XCTAssertFalse(element(app, "providerClaudeInstall").exists)
        shot(app, "provider-claude-not-found")
    }

    func testClaudeDirectSdkInstallsThePluginThenTestsAndSaves() throws {
        let app = launchStep()
        openProvider(app, Self.claudeID, action: "Set up")
        let headline = element(app, "providerHeroHeadline")
        waitUntil(15, "the plugin is reported missing") { headline.exists && headline.label == "Install the Claude plugin" }
        shot(app, "provider-claude-plugin")
        element(app, "providerClaudeInstall").hit()
        waitUntil(15, "Claude is ready after the plugin installs") { headline.exists && headline.label == "Claude is ready" }
        waitFor(element(app, "providerClaudeDisclosure"), timeout: 10, "plan allowance disclosure")
        shot(app, "provider-claude-ready")
        element(app, "providerClaudeContinue").hit()
        waitFor(element(app, "providerTest"), timeout: 15, "test screen")
        runTest(app)
        waitForState(app, "passed")
        XCTAssertTrue(element(app, "providerTestSaveAndContinue").isEnabled)
    }
}
#endif
