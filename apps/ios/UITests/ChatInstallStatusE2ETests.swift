import XCTest

@MainActor
final class ChatInstallStatusE2ETests: BotProfileTestCase {
    func testUnavailableStateIsCenteredWithItsActionBesideTheText() throws {
        let app = signedInApp(
            connectedServices: ["slack"], extraArguments: ["-hermes-test-chat-install", "-hermes-test-chat-install-fail"]
        )
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        let status = element(app, "chatInstallStatus")
        waitFor(status, timeout: 30, "status block")
        let title = app.staticTexts["Can't reach Slack setup"]
        let primary = element(app, "chatInstallPrimary")
        waitFor(title, timeout: 10, "status title")
        waitFor(primary, timeout: 10, "retry action")
        XCTAssertLessThanOrEqual(primary.frame.minY - title.frame.maxY, 96, "the action sits right under the text")
        XCTAssertGreaterThan(primary.frame.minY, title.frame.maxY, "the action is below the title")
        let area = element(app, "chatInstallScreen").frame
        let block = title.frame.union(primary.frame)
        XCTAssertEqual(block.midX, area.midX, accuracy: 24, "the block is centered horizontally")
        XCTAssertEqual(block.midY, area.midY, accuracy: 72, "the block is centered vertically")
        XCTAssertLessThanOrEqual(status.frame.width, 440, "the block keeps a readable width")
        let details = element(app, "chatInstallDetails")
        XCTAssertFalse(element(app, "chatInstallCopyDetails").exists, "details start collapsed")
        details.hit()
        waitFor(element(app, "chatInstallCopyDetails"), timeout: 10, "copy button")
        XCTAssertEqual(element(app, "chatInstallReasonCode").label, "forbidden", "details name the reason code")
    }
}
