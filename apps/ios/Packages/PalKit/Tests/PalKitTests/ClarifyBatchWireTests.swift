import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Clarify batch wire")
struct ClarifyBatchWireTests {
    private static let params: JSONValue = [
        "session_id": "s1",
        "questions": [
            ["qid": "q0", "question": "Platforms?", "choices": ["Mac", "iPhone"], "multi_select": false],
            ["qid": "q1", "question": "Parts?", "choices": ["Setup", "Kanban"], "multi_select": true],
            ["qid": "q2", "question": "Anything else?"],
        ],
    ]

    @Test func theRequestBecomesOnePromptCarryingEveryQuestionInOrder() throws {
        let prompt = try #require(PendingPrompt.clarifyBatch(requestID: "srq-1", params: Self.params, sessionID: "s1"))
        #expect(prompt.kind == .clarify && prompt.promptID == "srq-1")
        #expect(prompt.questions.map(\.qid) == ["q0", "q1", "q2"])
        #expect(prompt.questions.map(\.question) == ["Platforms?", "Parts?", "Anything else?"])
        #expect(prompt.questions[1].multiSelect && prompt.questions[2].choices.isEmpty)
        #expect(prompt.isBatch && prompt.isForm)
        #expect(prompt.question == "Platforms?" && prompt.choices == ["Mac", "iPhone"])
    }

    @Test func oneQuestionIsABatchButNotAForm() throws {
        let one: JSONValue = ["session_id": "s1", "questions": [["qid": "q0", "question": "Merge?", "choices": ["Yes", "No"]]]]
        let prompt = try #require(PendingPrompt.clarifyBatch(requestID: "srq-2", params: one, sessionID: "s1"))
        #expect(prompt.isBatch && !prompt.isForm)
    }

    @Test func aRequestForAnotherSessionOrWithoutQuestionsIsRefused() {
        #expect(PendingPrompt.clarifyBatch(requestID: "srq-1", params: Self.params, sessionID: "other") == nil)
        #expect(PendingPrompt.clarifyBatch(requestID: "srq-1", params: ["session_id": "s1", "questions": []], sessionID: "s1") == nil)
        #expect(PendingPrompt.clarifyBatch(requestID: "srq-1", params: nil, sessionID: "s1") == nil)
    }

    @Test func aPerQuestionPromptStaysAPlainPrompt() throws {
        let wire: JSONValue = ["kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which?", "choices": ["a", "b"]]
        let prompt = try wire.decoded(as: PendingPrompt.self)
        #expect(!prompt.isBatch && !prompt.isForm && prompt.questions.isEmpty)
    }

    @Test func requestCancelSettlesTheRequestTheWayAClarifySettledDoes() {
        let cancel = SessionEvent(type: "request.cancel", payload: ["id": "srq-1", "method": "clarify", "reason": "resolved"])
        #expect(cancel == .clarifySettled(PromptSettled(promptID: "srq-1")))
        let settled = SessionEvent(type: "clarify.settled", payload: ["prompt_id": "p1"])
        #expect(settled == .clarifySettled(PromptSettled(promptID: "p1")))
    }

    @Test func aSnapshotWithAnOpenClarifyRequestCarriesItAsAPendingPrompt() throws {
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0,
            "open_requests": [["id": "srq-4", "method": "clarify", "params": Self.params], ["id": "srq-5", "method": "sudo", "params": [:]]],
        ]
        let decoded = try snapshot.decoded(as: SessionSnapshot.self)
        #expect(decoded.prompts.map(\.promptID) == ["srq-4"])
        #expect(decoded.prompts.first?.isForm == true)
    }

    @Test func answeredItemsOfOneCallShareItsCallID() {
        #expect(ClarifyRecord.callID(ofItemID: "tool:call_9#0") == "call_9")
        #expect(ClarifyRecord.callID(ofItemID: "tool:call_9#2") == "call_9")
        #expect(ClarifyRecord.callID(ofItemID: "tool:call_9") == nil)
        #expect(ClarifyRecord.callID(ofItemID: "prompt:p1") == nil)
    }

    @Test func aBatchToolResultYieldsOneAnsweredItemPerQuestionInOrder() throws {
        let json = """
        {"responses": [{"question": "A?", "status": "answered", "user_response": "x"},
        {"question": "B?", "status": "skipped", "user_response": null},
        {"question": "C?", "status": "answered", "user_response": ["p", "q"]}], "outcome": "submitted"}
        """
        var transcript = Transcript()
        let snapshot: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        let frame = SessionEventFrame(
            event: SessionEvent(type: "tool.complete", payload: ["tool_id": "t1", "name": "clarify", "result": .string(json)]),
            sessionID: "s1", seq: 1, replayEpoch: "e1"
        )
        _ = transcript.apply(frame)
        #expect(transcript.items.map(\.id) == ["tool:t1#0", "tool:t1#1", "tool:t1#2"])
        #expect(Set(transcript.items.compactMap { ClarifyRecord.callID(ofItemID: $0.id) }) == ["t1"])
    }
}
