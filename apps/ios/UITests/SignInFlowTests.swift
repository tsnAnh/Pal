import XCTest

@MainActor
final class SignInFlowTests: E2ETestCase {
    func testNativeSignInThroughWebAuthenticationSession() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)

        app.buttons["userAvatarButton"].tap()
        waitFor(app.descendants(matching: .any)["settingsSheet"], timeout: 15, "settings sheet")
        let account = app.buttons["settingsAccountRow"]
        waitFor(account, timeout: 15, "account row")
        let host = try XCTUnwrap(URL(string: env.baseURL)?.host(), "base URL host")
        XCTAssertTrue(account.label.contains(host), "the account row names the signed-in gateway: \(account.label)")
        shot(app, "signed-in-settings")
    }
}
