import XCTest

@MainActor
final class MachineTurnE2ETests: E2ETestCase {
    private let marker = "ASYNC DELEGATION"

    private func noOwnerBubbleCarriesTheMarker(_ app: XCUIApplication, _ moment: String) {
        XCTAssertEqual(bubbles(app, "userBubble", containing: marker).count, 0, "\(moment): a machine turn painted as the owner's bubble\n\(app.debugDescription)")
    }

    private func waitForFollowUp(_ app: XCUIApplication, timeout: TimeInterval) {
        let notice = app.descendants(matching: .any).matching(identifier: "inboundNotice").firstMatch
        waitFor(notice, timeout: timeout, "the delegation completion lands as a notice")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let replies = app.descendants(matching: .any).matching(identifier: "assistantBubble")
            if replies.count > 0, replies.element(boundBy: replies.count - 1).frame.minY > notice.frame.minY { return }
            noOwnerBubbleCarriesTheMarker(app, "while the completion runs")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the bot's follow-up reply to the completion never appeared\n\(app.debugDescription)")
    }

    func test1DelegationCompletionIsANoticeLiveAndAfterReopening() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        shot(app, "machine-turn-1-open")

        try control("external-delegate-alpha")
        waitForFollowUp(app, timeout: 120)
        noOwnerBubbleCarriesTheMarker(app, "live")
        shot(app, "machine-turn-2-live")

        app.terminate()
        let reopened = launch()
        signInIfNeeded(reopened)
        openBot(reopened, "bot-alpha")
        waitFor(reopened.descendants(matching: .any).matching(identifier: "inboundNotice").firstMatch, timeout: 30, "notice after reopening")
        noOwnerBubbleCarriesTheMarker(reopened, "after reopening")
        shot(reopened, "machine-turn-3-reopened")
        try control("stop-external")
    }
}
