import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("An admitted message's late stream echo")
struct AdmittedEchoReconciliationTests {
    private func runningTranscript() throws -> Transcript {
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [["role": "user", "text": "go", "row_id": 1]], "running": true,
            "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func apply(_ transcript: inout Transcript, _ sequence: Int, _ type: String, _ payload: JSONValue) {
        let frame = SessionEventFrame(
            event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: sequence, replayEpoch: "e1", executionGeneration: 1
        )
        _ = transcript.apply(frame)
    }

    private func users(_ transcript: Transcript) -> [(text: String, delivery: TranscriptItem.Delivery)] {
        transcript.items.compactMap { item in
            if case .user(let text, let delivery) = item.content { (text, delivery) } else { nil }
        }
    }

    @Test func aQueuedListingAndTheAbsorbEchoNeverMakeASecondBubble() throws {
        var transcript = try runningTranscript()
        transcript.echoUser(submissionID: "s1", text: "also this")
        let queued: JSONValue = ["admission_id": "a-s1", "status": "queued", "input_id": "s1", "text": "also this"]
        apply(&transcript, 1, "session.info", ["running": true, "pending": [queued]])
        #expect(users(transcript).map(\.text) == ["go", "also this"])
        #expect(users(transcript).last?.delivery == .sending)
        apply(&transcript, 2, "input.absorbed", [
            "turn_id": "t1", "admission_ids": ["a-s1"], "message_uid": "m-1", "text": "also this",
        ])
        #expect(users(transcript).map(\.text) == ["go", "also this"])
        #expect(users(transcript).map(\.delivery) == [.sent, .sent])
    }

    @Test func twoAdmittedEchoesAbsorbedTogetherStayTwoBubblesInSendOrder() throws {
        var transcript = try runningTranscript()
        transcript.echoUser(submissionID: "s1", text: "one")
        transcript.echoUser(submissionID: "s2", text: "two")
        apply(&transcript, 1, "input.absorbed", [
            "turn_id": "t1", "admission_ids": ["a1", "a2"], "message_uid": "m-1", "text": "one\n\ntwo",
        ])
        #expect(users(transcript).map(\.text) == ["go", "one", "two"])
        #expect(users(transcript).map(\.delivery) == [.sent, .sent, .sent])
    }
}
