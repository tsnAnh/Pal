import XCTest

@MainActor
final class PresenceCrossClientE2ETests: E2ETestCase {
    private static let jobTimeout: TimeInterval = 420

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let required = ["HERMES_UITEST_PRESENCE_CROSS", "HERMES_UITEST_PRESENCE_RUN", "HERMES_UITEST_CTL", "HERMES_UITEST_BASE_URL"]
        let missing = required.filter { env[$0]?.isEmpty ?? true }
        try XCTSkipUnless(missing.isEmpty, "cross-client presence E2E needs \(missing.joined(separator: ", "))")
        try await super.setUp()
    }

    func test1DesktopThenPhoneShareOneChatAndOneReach() throws {
        let environment = ProcessInfo.processInfo.environment
        let bot = environment["HERMES_UITEST_PRESENCE_BOT"] ?? "bot-alpha"
        let run = try XCTUnwrap(environment["HERMES_UITEST_PRESENCE_RUN"])

        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        openBot(app, bot)

        try control("desktop-turn-1", timeout: 240)

        for turn in [2, 3] {
            let text = "PRESENCE-T\(turn)-\(run)"
            let repliesBefore = bubbles(app, "assistantBubble", containing: "stub-39").count
            send(app, text)
            waitFor(bubbles(app, "userBubble", containing: text).firstMatch, timeout: 20, "user bubble for turn \(turn)")
            let deadline = Date().addingTimeInterval(90)
            while bubbles(app, "assistantBubble", containing: "stub-39").count <= repliesBefore, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertGreaterThan(bubbles(app, "assistantBubble", containing: "stub-39").count, repliesBefore, "reply completes for turn \(turn)")
        }
        shot(app, "presence-turns-done")
        try control("assert-notes")

        try control("fire-job-1")
        let banner = app.descendants(matching: .any)["reach-offer-banner"]
        waitFor(banner, timeout: Self.jobTimeout, "offer banner while the phone is in the foreground")
        if let expected = environment["HERMES_UITEST_PRESENCE_TITLE_1"], !expected.isEmpty {
            XCTAssertTrue(banner.label.contains(expected), "banner label \(banner.label) contains \(expected)")
        }
        shot(app, "presence-offer-banner")
        banner.tap()
        waitGone(banner, timeout: 10, "banner leaves after the tap")
        try control("assert-row-1", timeout: 90)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackgroundSuspended, timeout: 20) || app.state == .runningBackground,
            "the phone app left the foreground (state \(app.state.rawValue))"
        )
        try control("fire-job-2", timeout: Self.jobTimeout)
        try control("assert-row-2", timeout: 90)

        app.terminate()
        try control("quit-desktop", timeout: 120)
        try control("fire-job-3", timeout: Self.jobTimeout)
        try control("assert-row-3", timeout: 90)
        try control("assert-beta", timeout: 120)
    }
}
