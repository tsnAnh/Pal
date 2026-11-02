import Foundation
import HermesChat
import HermesProtocol
import Testing

@Suite("Transcript reducer")
struct TranscriptReducerTests {
    private func snapshot(
        messages: [WireMessage] = [],
        running: Bool = false,
        lastSequence: Int = 0,
        epoch: String = "e1",
        pending: [PendingAdmission] = []
    ) throws -> SessionSnapshot {
        let object: JSONValue = [
            "session_id": "s1",
            "messages": .array(messages.map { message in
                var row: [String: JSONValue] = ["role": .string(message.role), "text": .string(message.plainText)]
                if let id = message.rowID { row["row_id"] = .int(id) }
                return .object(row)
            }),
            "running": .bool(running),
            "replay_epoch": .string(epoch),
            "last_sequence": .int(lastSequence),
            "execution_generation": 1,
            "pending": .array(pending.map { admission in
                .object([
                    "admission_id": .string(admission.admissionID),
                    "status": .string(admission.status.rawValue),
                    "input_id": .string(admission.inputID ?? ""),
                    "text": .string(admission.text ?? ""),
                ])
            }),
            "prompts": [],
        ]
        return try object.decoded(as: SessionSnapshot.self)
    }

    private func frame(_ type: String, _ payload: JSONValue, seq: Int, epoch: String = "e1") -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: epoch)
    }

    private func message(_ role: String, _ text: String, row: Int) -> WireMessage {
        WireMessage(role: role, text: text, rowID: row)
    }

    @Test func eventsAtOrBelowTheCursorAreIgnored() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot(lastSequence: 5))
        #expect(transcript.apply(frame("message.delta", ["text": "a", "segment": 0, "offset": 0], seq: 5)) == .duplicate)
        #expect(transcript.apply(frame("message.delta", ["text": "a", "segment": 0, "offset": 0], seq: 6)) == .applied)
        #expect(transcript.apply(frame("message.delta", ["text": "a", "segment": 0, "offset": 0], seq: 6)) == .duplicate)
        #expect(transcript.assistantTexts == ["a"])
    }

    @Test func completeTextOverridesAccumulatedDeltas() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        _ = transcript.apply(frame("message.delta", ["text": "hel", "segment": 0, "offset": 0], seq: 1))
        _ = transcript.apply(frame("message.delta", ["text": "lo ", "segment": 0, "offset": 3], seq: 2))
        _ = transcript.apply(frame("message.complete", ["text": "hello"], seq: 3))
        #expect(transcript.assistantTexts == ["hello"])
        #expect(!transcript.isRunning)
    }

    @Test func resentChunkWithAnAppliedOffsetIsDropped() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        _ = transcript.apply(frame("message.delta", ["text": "abc", "segment": 0, "offset": 0], seq: 1))
        _ = transcript.apply(frame("message.delta", ["text": "abc", "segment": 0, "offset": 0], seq: 2))
        #expect(transcript.assistantTexts == ["abc"])
    }

    @Test func unknownEventTypesNeverBreakTheStream() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        #expect(transcript.apply(frame("brand.new.event", ["x": 1], seq: 1)) == .applied)
        #expect(transcript.apply(frame("message.delta", "not an object", seq: 2)) == .applied)
        #expect(transcript.cursor?.lastSequence == 2)
        guard case .unknown(let type, _) = SessionEvent(type: "brand.new.event", payload: ["x": 1]) else {
            Issue.record("expected an unknown event")
            return
        }
        #expect(type == "brand.new.event")
    }

    @Test func epochChangeAndReplayGapDemandAResync() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot(lastSequence: 3))
        #expect(transcript.apply(frame("message.delta", ["text": "x"], seq: 4, epoch: "other")) == .resyncRequired(.epochChanged))
        #expect(transcript.resyncRequested)
        let fresh = try snapshot(messages: [message("user", "hi", row: 1)], lastSequence: 9, epoch: "other")
        let replaced = transcript.reconcile(with: fresh)
        #expect(replaced)
        #expect(!transcript.resyncRequested)
        #expect(transcript.cursor == StreamCursor(replayEpoch: "other", lastSequence: 9))

        var gapped = Transcript()
        _ = gapped.reconcile(with: try snapshot())
        let gap = SessionEventFrame(event: SessionEvent(type: "session.replay_gap", payload: ["latest_seq": 7]), sessionID: "s1")
        #expect(gapped.apply(gap) == .resyncRequired(.replayGap))
    }

    @Test func staleCompleteAfterASnapshotThatHoldsTheTurnAddsNothing() throws {
        var transcript = Transcript()
        let done = try snapshot(
            messages: [message("user", "q", row: 1), message("assistant", "answer", row: 2)],
            running: true,
            lastSequence: 10,
            pending: [PendingAdmission(admissionID: "a", status: .started, sequence: 1, inputID: "i", text: "q", executionGeneration: 1)]
        )
        _ = transcript.reconcile(with: done)
        _ = transcript.apply(frame("message.complete", ["text": "answer"], seq: 11))
        #expect(transcript.summary().conversation.map(\.kind) == ["user", "assistant"])
    }

    @Test func snapshotBehindTheCursorKeepsTheLiveTranscript() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot(lastSequence: 1))
        _ = transcript.apply(frame("message.delta", ["text": "live", "segment": 0, "offset": 0], seq: 2))
        let replaced = transcript.reconcile(with: try snapshot(lastSequence: 1))
        #expect(!replaced)
        #expect(transcript.assistantTexts == ["live"])
    }

    @Test func clarifyCardLivesUntilSettled() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        let prompt: JSONValue = [
            "kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which?", "choices": ["a", "b"],
        ]
        _ = transcript.apply(frame("clarify.request", prompt, seq: 1))
        _ = transcript.apply(frame("clarify.request", prompt, seq: 2))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["p1"])
        _ = transcript.apply(frame("clarify.settled", ["prompt_id": "p1"], seq: 3))
        #expect(transcript.pendingPrompts.isEmpty)
    }

    private func info(_ status: String, text: String, input: String) -> JSONValue {
        let admission: JSONValue = [
            "admission_id": .string("a-\(input)"), "status": .string(status), "input_id": .string(input), "text": .string(text),
        ]
        return ["running": true, "pending": [admission]]
    }

    @Test func aTurnSubmittedElsewhereAppearsFromAdmissionInfo() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        _ = transcript.apply(frame("session.info", info("queued", text: "from another device", input: "i1"), seq: 1))
        _ = transcript.apply(frame("message.start", [:], seq: 2))
        _ = transcript.apply(frame("session.info", info("started", text: "from another device", input: "i1"), seq: 3))
        _ = transcript.apply(frame("message.complete", ["text": "ok"], seq: 4))
        #expect(transcript.summary().conversation.map(\.text) == ["from another device", "ok"])
    }

    @Test func localEchoAndAdmissionInfoDescribeOneUserBubble() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        transcript.echoUser(submissionID: "i1", text: "mine")
        _ = transcript.apply(frame("session.info", info("queued", text: "mine", input: "i1"), seq: 1))
        _ = transcript.apply(frame("session.info", info("started", text: "mine", input: "i1"), seq: 2))
        #expect(transcript.summary().conversation.map(\.text) == ["mine"])
    }

    @Test func startedInfoAfterASnapshotThatHoldsTheUserRowAddsNothing() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot(messages: [message("user", "q", row: 1)], running: true, lastSequence: 4))
        _ = transcript.apply(frame("session.info", info("started", text: "q", input: "i1"), seq: 5))
        #expect(transcript.summary().conversation.map(\.text) == ["q"])
    }
}
