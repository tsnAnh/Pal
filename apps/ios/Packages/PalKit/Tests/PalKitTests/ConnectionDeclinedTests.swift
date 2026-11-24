import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Connection cards without an Allow step")
struct ConnectionDeclinedTests {
    private func opened(_ payload: JSONValue) throws -> Transcript {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try CardFixture.snapshot())
        #expect(transcript.apply(CardFixture.frame("connection.request", payload, seq: 2)) == .applied)
        return transcript
    }

    @Test func aPendingMCPRowOffersNoDecisionAndTheCardIsNotActionable() throws {
        let transcript = try opened(CardFixture.request(targets: [CardFixture.target(state: "pending")]))
        let card = try #require(cardsOf(transcript).first)
        #expect(card.decisions(for: try #require(card.operation.targets.first), now: Date()).isEmpty)
        #expect(!card.isActionable(now: Date()))
        #expect(transcript.pendingConnections().isEmpty)
    }

    @Test func aFailedMCPRowOffersOnlyTryAgainThatAnswersApproved() throws {
        let transcript = try opened(CardFixture.request(targets: [CardFixture.target(state: "failed")]))
        let card = try #require(cardsOf(transcript).first)
        let target = try #require(card.operation.targets.first)
        #expect(card.decisions(for: target, now: Date()) == [.tryAgain])
        #expect(ConnectionDecision.tryAgain.answerStatus == "approved")
        #expect(card.isActionable(now: Date()))
    }

    @Test func aRowOnlyConnectedInitiatedOrDeclinedIsNotActionable() throws {
        let transcript = try opened(CardFixture.request(targets: [
            CardFixture.target("a-server", state: "connected"),
            CardFixture.target("b-server", state: "initiated"),
            CardFixture.target("c-server", state: "declined"),
        ]))
        let card = try #require(cardsOf(transcript).first)
        #expect(!card.isActionable(now: Date()))
        #expect(transcript.pendingConnections().isEmpty)
    }

    @Test func declinedDecodesAndRoundTrips() throws {
        let transcript = try opened(CardFixture.request(targets: [CardFixture.target(state: "declined")]))
        let state = try #require(stateOf(cardsOf(transcript).first))
        #expect(state == .declined)
        #expect(state.rawValue == "declined")
        #expect(ConnectionTargetState(rawValue: "skipped") == .skipped)
    }

    @Test func aSettledToolResultWithADeclinedRowRendersAClosedCard() throws {
        let row: JSONValue = [
            "role": "tool", "name": "manage_connections", "tool_call_id": "call-1", "row_id": 1,
            "content": .string(CardFixture.toolResult(seq: 6, state: "declined")),
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try CardFixture.snapshot(messages: [row]))
        let card = try #require(cardsOf(transcript).first)
        #expect(card.operation.settled)
        #expect(!card.isOpen(now: Date()))
        #expect(stateOf(card) == .declined)
        #expect(!card.isActionable(now: Date()))
        #expect(transcript.pendingConnections().isEmpty)
    }
}
