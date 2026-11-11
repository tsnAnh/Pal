import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Answered clarify cards")
struct ClarifyRecordTests {
    private static let answered = """
    {"responses": [{"question": "Which flavor?", "choices_offered": ["vanilla", "chocolate"], "status": "answered", "user_response": "chocolate"}], "outcome": "submitted"}
    """

    private func frame(_ type: String, _ payload: JSONValue, seq: Int) -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: "e1")
    }

    private func liveTranscript() throws -> Transcript {
        var transcript = Transcript()
        let snapshot: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func history(_ rows: [JSONValue]) throws -> Transcript {
        var transcript = Transcript()
        let snapshot: JSONValue = ["session_id": "s1", "messages": .array(rows), "replay_epoch": "e1", "last_sequence": 0]
        transcript.load(try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func records(_ transcript: Transcript) -> [ClarifyRecord] {
        transcript.items.compactMap { item in
            if case .clarifyAnswered(let record) = item.content { return record }
            return nil
        }
    }

    @Test func liveToolCompleteReplacesTheToolRowWithTheAnswer() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.start", ["tool_id": "t1", "name": "clarify"], seq: 1))
        _ = transcript.apply(frame("clarify.request", ["kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?", "choices": ["vanilla", "chocolate"]], seq: 2))
        _ = transcript.apply(frame("clarify.settled", ["prompt_id": "p1"], seq: 3))
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "clarify", "result": .string(Self.answered)], seq: 4))
        #expect(records(transcript) == [ClarifyRecord(question: "Which flavor?", answer: .answered(["chocolate"]))])
        #expect(transcript.items.map(\.id) == ["tool:t1#0"])
        #expect(transcript.pendingPrompts.isEmpty)
    }

    @Test func replayedToolCompleteDoesNotDuplicateTheAnswer() throws {
        var transcript = try liveTranscript()
        let payload: JSONValue = ["tool_id": "t1", "name": "clarify", "result": .string(Self.answered)]
        _ = transcript.apply(frame("tool.complete", payload, seq: 1))
        _ = transcript.apply(frame("tool.complete", payload, seq: 2))
        #expect(records(transcript).count == 1)
    }

    @Test func skippedAndUnansweredBothReadAsSkipped() throws {
        let json = """
        {"responses": [{"question": "A?", "choices_offered": null, "status": "skipped", "user_response": null}, {"question": "B?", "choices_offered": ["x"], "status": "unanswered", "user_response": null}], "outcome": "timed_out"}
        """
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "clarify", "result": .string(json)], seq: 1))
        #expect(records(transcript) == [
            ClarifyRecord(question: "A?", answer: .skipped),
            ClarifyRecord(question: "B?", answer: .skipped),
        ])
        #expect(transcript.items.map(\.id) == ["tool:t1#0", "tool:t1#1"])
    }

    @Test func multiSelectAnswerKeepsEveryPick() throws {
        let json = """
        {"responses": [{"question": "Toppings?", "choices_offered": ["a", "b", "c"], "status": "answered", "user_response": ["a", "c"]}], "outcome": "submitted"}
        """
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "clarify", "result": .string(json)], seq: 1))
        #expect(records(transcript) == [ClarifyRecord(question: "Toppings?", answer: .answered(["a", "c"]))])
    }

    @Test func unparseableResultFallsBackToAHiddenToolRow() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "clarify", "result": "not json"], seq: 1))
        #expect(records(transcript).isEmpty)
        #expect(transcript.summary().items.map(\.kind) == ["tool"])
    }

    @Test func nonClarifyToolWithAnAnswerShapedResultIsNotTreatedAsOne() throws {
        var transcript = try liveTranscript()
        _ = transcript.apply(frame("tool.complete", ["tool_id": "t1", "name": "terminal", "result": .string(Self.answered)], seq: 1))
        #expect(records(transcript).isEmpty)
    }

    @Test func historyToolRowBecomesTheSameAnsweredCard() throws {
        let transcript = try history([
            ["role": "user", "text": "ask", "row_id": 1],
            ["role": "tool", "name": "clarify", "tool_call_id": "t1", "text": .string(Self.answered), "row_id": 2],
            ["role": "assistant", "text": "Got it, chocolate.", "row_id": 3],
        ])
        #expect(records(transcript) == [ClarifyRecord(question: "Which flavor?", answer: .answered(["chocolate"]))])
        #expect(transcript.items.map(\.id) == ["row:1", "tool:t1#0", "row:3"])
    }

    @Test func historyToolRowWithoutANameIsRecognisedByItsShape() throws {
        let transcript = try history([["role": "tool", "tool_call_id": "t1", "text": .string(Self.answered), "row_id": 2]])
        #expect(records(transcript).count == 1)
    }

    @Test func historyToolRowOfAnotherToolStaysHidden() throws {
        let transcript = try history([["role": "tool", "name": "terminal", "tool_call_id": "t1", "text": .string(Self.answered), "row_id": 2]])
        #expect(records(transcript).isEmpty)
        #expect(transcript.summary().items.map(\.kind) == ["tool"])
    }
}
