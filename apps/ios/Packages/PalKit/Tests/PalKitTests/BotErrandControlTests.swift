import Foundation
import PalChat
import PalProtocol
import PalTransport
import Testing

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-control-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Bot errand control", .serialized)
struct BotErrandControlTests {
    private struct Rig {
        let script: BotScript
        let gateway: FakeGateway
        let hub: SessionHub
        let session: ChatSession
        let errand: BotErrand

        func push(_ type: String, seq: Int, _ payload: JSONValue = [:]) {
            gateway.push(script.event(type, seq: seq, payload: payload))
        }

        func running(from seq: Int = 2) async throws {
            push("message.start", seq: seq)
            try await waitUntil("a running turn", timeout: .seconds(10)) { await session.state.transcript.isRunning }
        }

        func raise(_ kind: String, id: String, seq: Int, extra: [String: JSONValue] = [:]) async throws {
            var payload: [String: JSONValue] = ["kind": .string(kind), "prompt_id": .string(id), "execution_generation": 1]
            payload.merge(extra) { _, new in new }
            push("\(kind).request", seq: seq, .object(payload))
            try await waitUntil("the \(kind) card", timeout: .seconds(10)) { await session.state.transcript.pendingPrompts.contains { $0.promptID == id } }
        }

        func finish() async {
            await hub.release(session)
            gateway.stop()
        }
    }

    private func rig(configure: (BotScript) -> Void = { _ in }) async throws -> Rig {
        let script = BotScript()
        configure(script)
        let gateway = try await FakeGateway.start(script.handle)
        let hub = SessionHub(profile: "bot", connector: ScriptedConnector(url: gateway.url))
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: hub)
        let session = await hub.acquire()
        let errand = BotErrand(botID: "bot", session: session, outbox: outbox, connectTimeout: .seconds(5))
        try await session.start()
        try await waitUntil("the live session", timeout: .seconds(10)) {
            if case .live = await session.state.phase { true } else { false }
        }
        return Rig(script: script, gateway: gateway, hub: hub, session: session, errand: errand)
    }

    @Test func lastReplyIsTheFinishedTextOfTheChat() async throws {
        let rig = try await rig { $0.messages.withLock { $0 = [("user", "hi"), ("assistant", "hello there")] } }
        #expect(try await rig.errand.lastReply() == LastReply(text: "hello there", botIsWorkingOnMore: false))
        await rig.finish()
    }

    @Test func lastReplyOfAChatThatNeverRepliedIsNil() async throws {
        let rig = try await rig()
        #expect(try await rig.errand.lastReply() == nil)
        await rig.finish()
    }

    @Test func answeringSendsTheChoiceToTheOpenQuestionAndReturnsWhatTheBotSaysNext() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("clarify", id: "p1", seq: 3, extra: ["question": "Which flavor?", "choices": ["vanilla", "chocolate"]])
        let answering = Task { try await rig.errand.answer("Chocolate", deadline: .seconds(10)) }
        try await waitUntil("clarify.respond", timeout: .seconds(10)) { rig.script.calls("clarify.respond").count == 1 }
        let sent = rig.script.calls("clarify.respond")[0]
        #expect(sent["answer"]?.stringValue == "chocolate")
        #expect(sent["prompt_id"]?.stringValue == "p1")
        #expect(sent["execution_generation"]?.intValue == 1)
        rig.push("clarify.settled", seq: 4, ["prompt_id": "p1"])
        rig.push("message.delta", seq: 5, ["text": "Chocolate then.", "segment": 1, "offset": 0])
        rig.push("message.complete", seq: 6, ["text": "Chocolate then."])
        #expect(try await answering.value == .answered(.replied("Chocolate then.")))
        await rig.finish()
    }

    @Test func answeringWithNothingAskedSendsNothing() async throws {
        let rig = try await rig()
        #expect(try await rig.errand.answer("anything", deadline: .seconds(1)) == .nothingToAnswer(waitingOn: nil))
        #expect(rig.script.calls("clarify.respond").isEmpty)
        await rig.finish()
    }

    @Test func answeringWhileOnlyAnApprovalIsOpenPointsAtTheApproval() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "a1", seq: 3, extra: ["command": "ls", "choices": ["once", "deny"]])
        guard case .nothingToAnswer(let waiting?) = try await rig.errand.answer("yes", deadline: .seconds(1)) else {
            Issue.record("expected nothingToAnswer with the approval")
            return
        }
        #expect(waiting.kind == .approval)
        #expect(rig.script.calls("clarify.respond").isEmpty)
        await rig.finish()
    }

    @Test func aRefusedAnswerIsNotAcceptedNotUnreachable() async throws {
        let rig = try await rig { script in
            script.override("clarify.respond") { _ in .failure(RPCError(code: 4009, message: "prompt already settled")) }
        }
        try await rig.running()
        try await rig.raise("clarify", id: "p1", seq: 3)
        await #expect(throws: ErrandError.notAccepted) { _ = try await rig.errand.answer("x", deadline: .seconds(1)) }
        await rig.finish()
    }

    @Test func anAnswerThatIsNeverFollowedByAReplyIsStillWorking() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("clarify", id: "p1", seq: 3)
        let answer = try await rig.errand.answer("x", deadline: .milliseconds(300))
        #expect(answer == .answered(.stillWorking))
        await rig.finish()
    }

    @Test(arguments: [(ApprovalDecision.approve, "once"), (ApprovalDecision.deny, "deny")])
    func decidingSendsTheMatchingChoice(decision: ApprovalDecision, choice: String) async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "a1", seq: 3, extra: ["command": "rm -rf build", "choices": ["once", "session", "always", "deny"]])
        let prompt = try #require(try await rig.errand.pendingApproval())
        try await rig.errand.decide(decision, on: prompt)
        let sent = rig.script.calls("approval.respond")
        #expect(sent.count == 1)
        #expect(sent[0]["choice"]?.stringValue == choice)
        #expect(sent[0]["prompt_id"]?.stringValue == "a1")
        await rig.finish()
    }

    @Test func approvingAPromptThatOffersNoOnceChoiceSendsNothing() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "a1", seq: 3, extra: ["choices": ["deny"]])
        let prompt = try #require(try await rig.errand.pendingApproval())
        await #expect(throws: ErrandError.notAccepted) { try await rig.errand.decide(.approve, on: prompt) }
        #expect(rig.script.calls("approval.respond").isEmpty)
        await rig.finish()
    }

    @Test func noPendingApprovalReadsAsNil() async throws {
        let rig = try await rig()
        #expect(try await rig.errand.pendingApproval() == nil)
        await rig.finish()
    }

    @Test func stoppingAnIdleBotSendsNothing() async throws {
        let rig = try await rig()
        #expect(try await rig.errand.stop() == .notRunning)
        #expect(rig.script.calls("session.interrupt").isEmpty)
        await rig.finish()
    }

    @Test func stoppingARunningBotInterruptsAndSettlesOnceItIsIdle() async throws {
        let rig = try await rig()
        try await rig.running()
        let stopping = Task { try await rig.errand.stop(settle: .seconds(10)) }
        try await waitUntil("session.interrupt", timeout: .seconds(10)) { rig.script.calls("session.interrupt").count == 1 }
        #expect(rig.script.calls("session.interrupt")[0]["execution_generation"]?.intValue == 1)
        rig.push("message.complete", seq: 3, ["text": "", "status": "interrupted"])
        #expect(try await stopping.value == .stopped)
        await rig.finish()
    }

    @Test func aBotThatKeepsRunningAfterStopIsReportedAsStopping() async throws {
        let rig = try await rig()
        try await rig.running()
        #expect(try await rig.errand.stop(settle: .milliseconds(200)) == .stopping)
        await rig.finish()
    }

    @Test func aRefusedStopIsNotAccepted() async throws {
        let rig = try await rig { script in
            script.override("session.interrupt") { _ in .failure(RPCError(code: 4001, message: "session not found")) }
        }
        try await rig.running()
        await #expect(throws: ErrandError.notAccepted) { _ = try await rig.errand.stop() }
        await rig.finish()
    }

    @Test func steeringARunningBotSendsGuidanceWithoutANewMessage() async throws {
        let rig = try await rig()
        try await rig.running()
        #expect(try await rig.errand.steer("use tabs") == .steered)
        #expect(rig.script.calls("session.steer").first?["text"]?.stringValue == "use tabs")
        #expect(rig.script.calls("session.steer").first?["execution_generation"]?.intValue == 1)
        #expect(rig.script.submitted.withLock { $0.isEmpty })
        await rig.finish()
    }

    @Test func steeringAnIdleBotStartsANewTaskInstead() async throws {
        let rig = try await rig()
        guard case .startedNewTask(let mark) = try await rig.errand.steer("use tabs") else {
            Issue.record("expected a new task")
            return
        }
        #expect(mark.text == "use tabs")
        #expect(rig.script.calls("session.steer").isEmpty)
        #expect(rig.script.submitted.withLock { $0.count } == 1)
        await rig.finish()
    }

    @Test func aSteerTheGatewayRejectsFallsBackToANormalMessage() async throws {
        let rig = try await rig { script in
            script.override("session.steer") { _ in .result(["status": "rejected", "text": "use tabs"]) }
        }
        try await rig.running()
        guard case .startedNewTask = try await rig.errand.steer("use tabs") else {
            Issue.record("expected a new task")
            return
        }
        #expect(rig.script.submitted.withLock { $0.count } == 1)
        await rig.finish()
    }

    @Test func tellingWithFilesStagesThemOnTheGatewayAndSubmitsPathsAndRefs() async throws {
        let rig = try await rig()
        let image = try OutgoingFile(name: "shot.png", mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let note = try OutgoingFile(name: "todo.txt", mime: "text/plain", data: Data("buy milk".utf8))
        _ = try await rig.errand.tell("please look", files: [image, note])
        let staged = rig.script.calls("image.attach_bytes")
        #expect(staged.count == 1)
        #expect(staged[0]["content_base64"]?.stringValue == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect(staged[0]["filename"]?.stringValue == "shot.png")
        let documents = rig.script.calls("file.attach")
        #expect(documents.count == 1)
        #expect(documents[0]["data_url"]?.stringValue == "data:text/plain;base64,\(Data("buy milk".utf8).base64EncodedString())")
        let submitted = try #require(rig.script.submitted.withLock { $0.first })
        #expect(submitted["text"]?.stringValue == "please look\n@file:attachments/todo.txt")
        let attachments = try #require(submitted["attachments"]?.arrayValue)
        #expect(attachments.count == 1)
        #expect(attachments[0]["path"]?.stringValue?.hasPrefix("/cache/images/upload_") == true)
        #expect(attachments[0]["mime"]?.stringValue == "image/png")
        await rig.finish()
    }

    @Test func anImageWithNoNoteIsSubmittedWithTheGatewaysOwnDescription() async throws {
        let rig = try await rig()
        let image = try OutgoingFile(name: "shot.png", mime: "image/png", data: Data([1, 2, 3]))
        _ = try await rig.errand.tell("", files: [image])
        let submitted = try #require(rig.script.submitted.withLock { $0.first })
        #expect(submitted["text"]?.stringValue?.hasPrefix("[User attached image:") == true)
        await rig.finish()
    }

    @Test func aTextOnlyTellSendsNoAttachmentsField() async throws {
        let rig = try await rig()
        _ = try await rig.errand.tell("just words")
        let submitted = try #require(rig.script.submitted.withLock { $0.first })
        #expect(submitted["attachments"] == nil)
        #expect(rig.script.calls("image.attach_bytes").isEmpty)
        await rig.finish()
    }

    @Test func aGatewayThatRefusesAFileFailsTheErrandAndKeepsTheEntryForARetry() async throws {
        let rig = try await rig { script in
            script.override("file.attach") { _ in .failure(RPCError(code: 4001, message: "invalid_params", data: ["reason": "invalid_params"])) }
        }
        let note = try OutgoingFile(name: "todo.txt", mime: "text/plain", data: Data("x".utf8))
        await #expect(throws: ErrandError.refused(reason: "invalid_params")) { _ = try await rig.errand.tell("note", files: [note]) }
        #expect(rig.script.submitted.withLock { $0.isEmpty })
        await rig.finish()
    }
}
