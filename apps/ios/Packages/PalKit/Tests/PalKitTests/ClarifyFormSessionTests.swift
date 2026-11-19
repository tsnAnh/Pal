import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let requestParams: JSONValue = [
    "session_id": "s1",
    "questions": [
        ["qid": "q0", "question": "Platforms?", "choices": ["Mac", "iPhone"], "multi_select": false],
        ["qid": "q1", "question": "Parts?", "choices": ["Setup", "Kanban"], "multi_select": true],
        ["qid": "q2", "question": "Anything else?", "multi_select": false],
    ],
]

private func openRequestsSnapshot(_ id: String) -> JSONValue {
    var object = BotScript().snapshot.objectValue ?? [:]
    object["running"] = true
    object["open_requests"] = [["id": .string(id), "method": "clarify", "params": requestParams]]
    return .object(object)
}

@Suite("Clarify batch request in a chat session", .serialized)
struct ClarifyFormSessionTests {
    private struct Rig {
        let script: BotScript
        let gateway: FakeGateway
        let hub: SessionHub
        let session: ChatSession

        func pendingPrompts() async -> [PendingPrompt] { await session.state.transcript.pendingPrompts }

        func formRows() async -> [PendingPrompt] {
            await session.timelineSnapshot.rows.compactMap { row in
                if case .clarify(let card) = row.item.content { return card.prompt }
                return nil
            }
        }

        func finish() async {
            await hub.release(session)
            gateway.stop()
        }
    }

    private func rig(configure: (BotScript) -> Void = { _ in }) async throws -> Rig {
        let script = BotScript()
        script.override("client.capabilities") { _ in
            .result(["server_requests": [], "declines_not_shown": true, "canonical_clarify_batch": true])
        }
        script.override("clarify.lock") { _ in .result(["status": "ok", "remaining": []]) }
        configure(script)
        let gateway = try await FakeGateway.start(script.handle)
        let hub = SessionHub(profile: "bot", connector: ScriptedConnector(url: gateway.url))
        let session = await hub.acquire()
        _ = await session.awaitState { if case .live = $0.phase { true } else { false } }
        return Rig(script: script, gateway: gateway, hub: hub, session: session)
    }

    @Test func aBatchOfThreeQuestionsIsOneFormRow() async throws {
        let rig = try await rig()
        rig.gateway.pushRequest(id: "srq-1", method: "clarify", params: requestParams)
        try await waitUntil("the form", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        let rows = await rig.formRows()
        #expect(rows.count == 1)
        let prompt = try #require(rows.first)
        #expect(prompt.isForm && prompt.promptID == "srq-1")
        #expect(prompt.questions.map(\.qid) == ["q0", "q1", "q2"])
        #expect(prompt.questions.map(\.multiSelect) == [false, true, false])
        #expect(prompt.questions[2].choices.isEmpty)
        await rig.finish()
    }

    @Test func submitLocksEveryAnswerInQuestionOrderWithSkippedAsNull() async throws {
        let rig = try await rig()
        rig.gateway.pushRequest(id: "srq-1", method: "clarify", params: requestParams)
        try await waitUntil("the form", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        let prompt = try #require(await rig.pendingPrompts().first)
        try await rig.session.answerClarifyForm(prompt, answers: [
            (qid: "q0", answer: .answered("Mac")),
            (qid: "q1", answer: .answered(#"["Setup","Kanban"]"#)),
            (qid: "q2", answer: .skipped),
        ])
        let locks = rig.script.calls("clarify.lock")
        #expect(locks.map { $0["question_id"]?.stringValue } == ["q0", "q1", "q2"])
        #expect(locks.allSatisfy { $0["request_id"]?.stringValue == "srq-1" })
        #expect(locks.map { $0["answer"] ?? "<missing>" } == ["Mac", .string(#"["Setup","Kanban"]"#), .null])
        await rig.finish()
    }

    @Test func theGatewaySettlingTheRequestRemovesTheForm() async throws {
        let rig = try await rig()
        rig.gateway.pushRequest(id: "srq-1", method: "clarify", params: requestParams)
        try await waitUntil("the form", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        rig.gateway.push(rig.script.event("request.cancel", seq: 2, payload: ["id": "srq-1", "method": "clarify", "reason": "resolved"]))
        try await waitUntil("the form gone", timeout: .seconds(10)) { await rig.pendingPrompts().isEmpty }
        #expect(await rig.formRows().isEmpty)
        await rig.finish()
    }

    @Test func aSingleQuestionBatchAnswersWithOneLock() async throws {
        let rig = try await rig()
        let single: JSONValue = [
            "session_id": "s1",
            "questions": [["qid": "q0", "question": "Merge it?", "choices": ["Yes", "No"], "multi_select": false]],
        ]
        rig.gateway.pushRequest(id: "srq-9", method: "clarify", params: single)
        try await waitUntil("the card", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        let prompt = try #require(await rig.pendingPrompts().first)
        #expect(!prompt.isForm && prompt.isBatch && prompt.question == "Merge it?" && prompt.choices == ["Yes", "No"])
        try await rig.session.answerClarify(prompt, answer: "Yes")
        try await rig.session.answerClarify(prompt, answer: "")
        let locks = rig.script.calls("clarify.lock")
        #expect(locks.map { $0["answer"] ?? "<missing>" } == ["Yes", .null])
        #expect(locks.allSatisfy { $0["request_id"]?.stringValue == "srq-9" && $0["question_id"]?.stringValue == "q0" })
        #expect(rig.script.count("clarify.respond") == 0)
        await rig.finish()
    }

    @Test func aFormCannotBeAnsweredWithOneTypedReply() async throws {
        let rig = try await rig()
        rig.gateway.pushRequest(id: "srq-1", method: "clarify", params: requestParams)
        try await waitUntil("the form", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        let prompt = try #require(await rig.pendingPrompts().first)
        await #expect(throws: ChatError.formNeedsAnswers) { try await rig.session.answerClarify(prompt, answer: "yes") }
        #expect(rig.script.count("clarify.lock") == 0)
        await rig.finish()
    }

    @Test func aFormStillOpenAtTheGatewayComesBackWithTheSnapshot() async throws {
        let rig = try await rig { script in
            script.override("session.resume") { _ in .result(openRequestsSnapshot("srq-7")) }
        }
        try await waitUntil("the restored form", timeout: .seconds(10)) { await rig.pendingPrompts().count == 1 }
        #expect(await rig.pendingPrompts().first?.isForm == true)
        #expect(await rig.pendingPrompts().first?.promptID == "srq-7")
        await rig.finish()
    }

    @Test func submitsDeclareTheBatchOnlyWhenTheGatewayAdvertisesIt() async throws {
        let supported = try await rig()
        try await supported.session.submitVoiceTurn("hello")
        #expect(supported.script.submitted.withLock { $0.last?["clarify_batch"] } == true)
        #expect(supported.script.calls("client.capabilities").first?["server_requests"] == true)
        await supported.finish()

        let older = try await rig { script in
            script.override("client.capabilities") { _ in
                .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
            }
        }
        try await older.session.submitVoiceTurn("hello")
        #expect(older.script.submitted.withLock { $0.last?["clarify_batch"] } == nil)
        await older.finish()
    }
}
