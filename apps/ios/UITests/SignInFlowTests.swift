import XCTest

@MainActor
final class SignInFlowTests: E2ETestCase {
    func testNativeSignInThroughWebAuthenticationSession() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)

        app.buttons["userAvatarButton"].tap()
        let status = app.staticTexts["statusLabel"]
        waitFor(status, timeout: 15, "settings status")
        XCTAssertEqual(status.label, "Connected")
        let instance = app.staticTexts["instanceIDLabel"]
        waitFor(instance, timeout: 10)
        XCTAssertFalse(instance.label.isEmpty)
        let attachment = XCTAttachment(string: "instance_id=\(instance.label)")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
