import XCTest

@MainActor
final class PresenceE2ETests: E2ETestCase {
    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let required = ["HERMES_UITEST_PRESENCE", "HERMES_UITEST_BASE_URL", "HERMES_UITEST_USERNAME", "HERMES_UITEST_PASSWORD"]
        let missing = required.filter { env[$0]?.isEmpty ?? true }
        try XCTSkipUnless(missing.isEmpty, "presence E2E needs \(missing.joined(separator: ", "))")
        try await super.setUp()
    }

    func test1OfferBannerAppearsAfterATurnAndTapActs() throws {
        let environment = ProcessInfo.processInfo.environment
        let bot = environment["HERMES_UITEST_PRESENCE_BOT"] ?? "bot-beta"
        let offerTimeout = TimeInterval(environment["HERMES_UITEST_PRESENCE_TIMEOUT"] ?? "") ?? 120

        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        openBot(app, bot)
        send(app, "hello from presence e2e")
        waitFor(bubbles(app, "userBubble", containing: "hello from presence e2e").firstMatch, timeout: 10, "user bubble")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60, "streamed reply")

        if let trigger = environment["HERMES_UITEST_PRESENCE_TRIGGER"], !trigger.isEmpty {
            try control(trigger)
        }

        let banner = app.descendants(matching: .any)["reach-offer-banner"]
        waitFor(banner, timeout: offerTimeout, "reach offer banner")
        XCTAssertFalse(banner.label.isEmpty, "banner carries the offer text")
        if let expected = environment["HERMES_UITEST_PRESENCE_TITLE"], !expected.isEmpty {
            XCTAssertTrue(banner.label.contains(expected), "banner label \(banner.label) contains \(expected)")
        }
        shot(app, "reach-offer-banner")

        banner.tap()
        waitGone(banner, timeout: 10, "banner leaves after the tap")
        shot(app, "reach-offer-acted")
    }

    func test2OfferBannerCloseButtonDismisses() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HERMES_UITEST_PRESENCE_DISMISS"] == "1" else {
            throw XCTSkip("set HERMES_UITEST_PRESENCE_DISMISS=1 when the orchestrator sends a second offer")
        }
        let offerTimeout = TimeInterval(environment["HERMES_UITEST_PRESENCE_TIMEOUT"] ?? "") ?? 120
        let app = launch()
        signInIfNeeded(app)
        let banner = app.descendants(matching: .any)["reach-offer-banner"]
        waitFor(banner, timeout: offerTimeout, "reach offer banner")
        let close = app.buttons["reach-offer-dismiss"]
        waitFor(close, timeout: 5, "close button")
        close.tap()
        waitGone(banner, timeout: 10, "banner leaves after dismiss")
    }
}
