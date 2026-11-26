import XCTest

@MainActor
final class LostTurnRecoveryE2ETests: E2ETestCase {
    func testChatAnswersAgainAfterTheGatewayDiesMidTurn() throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-beta")
        send(app, "SLOW LOST-TURN-4410")
        waitFor(app.descendants(matching: .any)["assistantBubble-streaming"], timeout: 30, "lost turn is running")
        shot(app, "chat-turn-running")
        try control("hard-kill-gateway")
        waitFor(app.descendants(matching: .any)["reconnectingIndicator"], timeout: 30, "reconnecting indicator")
        send(app, "AFTER-LOSS-5520")
        shot(app, "chat-follower-sent-offline")
        try control("start-gateway")
        XCTAssertNotNil(waitForReply(app, below: "AFTER-LOSS-5520", timeout: 120), "follower behind the lost turn is answered")
        shot(app, "chat-follower-answered")
        send(app, "NEXT-7781")
        XCTAssertNotNil(waitForReply(app, below: "NEXT-7781", timeout: 60), "a new message is answered")
        shot(app, "chat-next-answered")
        try control("lost-turn-resolved")
    }
}
