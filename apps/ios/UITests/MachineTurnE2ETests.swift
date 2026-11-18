import XCTest

@MainActor
final class MachineTurnE2ETests: E2ETestCase {
    private let marker = "ASYNC DELEGATION"

    private func noOwnerBubbleCarriesTheMarker(_ app: XCUIApplication, _ moment: String) {
        XCTAssertEqual(bubbles(app, "userBubble", containing: marker).count, 0, "\(moment): a machine turn painted as the owner's bubble\n\(app.debugDescription)")
    }

    private func noRowShowsTheCompletion(_ app: XCUIApplication, _ moment: String) {
        let notices = app.descendants(matching: .any).matching(identifier: "inboundNotice")
        XCTAssertEqual(notices.count, 0, "\(moment): a delegation completion painted as a row\n\(app.debugDescription)")
        noOwnerBubbleCarriesTheMarker(app, moment)
    }

    private func waitForFollowUp(_ app: XCUIApplication, after before: Int, timeout: TimeInterval) {
        let replies = app.descendants(matching: .any).matching(identifier: "assistantBubble")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if replies.count > before { return }
            noRowShowsTheCompletion(app, "while the completion runs")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the bot's follow-up reply to the completion never appeared\n\(app.debugDescription)")
    }

    func test1DelegationCompletionHasNoRowLiveAndAfterReopening() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        shot(app, "machine-turn-1-open")

        let repliesBefore = app.descendants(matching: .any).matching(identifier: "assistantBubble").count
        try control("external-delegate-alpha")
        waitForFollowUp(app, after: repliesBefore, timeout: 120)
        noRowShowsTheCompletion(app, "live")
        shot(app, "machine-turn-2-live")

        app.terminate()
        let reopened = launch()
        signInIfNeeded(reopened)
        openBot(reopened, "bot-alpha")
        waitFor(reopened.descendants(matching: .any).matching(identifier: "assistantBubble").firstMatch, timeout: 30, "the bot's reply after reopening")
        noRowShowsTheCompletion(reopened, "after reopening")
        shot(reopened, "machine-turn-3-reopened")
        try control("stop-external")
    }
}
