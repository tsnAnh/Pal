import XCTest

@MainActor
final class ChatInstallStatusE2ETests: BotProfileTestCase {
    func testAFailedSetupCallShowsOneStatusBlockWithItsDetailsBehindADisclosure() throws {
        let app = signedInApp(
            connectedServices: ["slack"], extraArguments: ["-hermes-test-chat-install", "-hermes-test-chat-install-fail"]
        )
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        waitFor(element(app, "slackSetupStatusBlock"), timeout: 30, "status block")
        XCTAssertEqual(element(app, "slackSetupStatusTitle").label, "Only the owner can do this")
        XCTAssertEqual(element(app, "slackSetupStatusAction").label, "Close", "one action")
        XCTAssertFalse(element(app, "slackSetupStatusCopyDetails").exists, "details start collapsed")
        element(app, "slackSetupStatusDetails").hit()
        waitFor(element(app, "slackSetupStatusCopyDetails"), timeout: 10, "copy button")
        let details = element(app, "slackSetupStatusDetailsText").label
        for line in ["code: forbidden", "method: chat.provider.list", "trace: 7f3k2m9a", "gateway 291aaa2b"] {
            XCTAssertTrue(details.contains(line), "details name \(line)")
        }
        element(app, "slackSetupStatusAction").hit()
        waitUntil(10, "closing leaves the status screen") { !element(app, "slackSetupStatusBlock").exists }
    }
}
