import XCTest

@MainActor
final class SignInFlowTests: E2ETestCase {
    func testNativeSignInThroughWebAuthenticationSession() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)

        app.buttons["userAvatarButton"].hit()
        #if os(macOS)
        waitFor(app.buttons["accountMenuSettings"], timeout: 10, "account menu")
        app.buttons["accountMenuSettings"].hit()
        #endif
        waitFor(app.descendants(matching: .any)["settingsSheet"], timeout: 15, "settings sheet")
        #if os(macOS)
        let account = app.descendants(matching: .any)["settingsAccountRow"]
        #else
        let account = app.buttons["settingsAccountRow"]
        #endif
        waitFor(account, timeout: 15, "account row")
        #if os(macOS)
        XCTAssertTrue(account.label.contains(env.username), "the account row names the signed-in account: \(account.label)")
        #else
        let host = try XCTUnwrap(URL(string: env.baseURL)?.host(), "base URL host")
        XCTAssertTrue(account.label.contains(host), "the account row names the signed-in gateway: \(account.label)")
        #endif
        shot(app, "signed-in-settings")
    }

    #if os(macOS)
    func testWrongPasswordIsRejectedWithoutSigningIn() throws {
        let app = launch(resetCredentials: true)
        enterAddress(app)
        enterNativeCredentials(app, password: env.password + "-wrong")
        app.buttons["signInButton"].hit()

        let error = app.staticTexts["errorLabel"]
        waitFor(error, timeout: 20, "wrong password error")
        XCTAssertEqual(error.value as? String ?? error.label, "Wrong username or password.")
        XCTAssertFalse(roster(app).exists, "a wrong password must not sign in")
        XCTAssertTrue(app.buttons["signInButton"].isEnabled)
        shot(app, "wrong-password")
    }
    #endif
}
