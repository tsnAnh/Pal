import Foundation
import PalChat
import PalDiagnostics
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-errand-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Bot errand against a scripted gateway", .serialized)
struct BotErrandTests {
    private struct Rig {
        let script: BotScript
        let gateway: FakeGateway
        let connector: ScriptedConnector
        let hub: SessionHub
        let outbox: Outbox
        let session: ChatSession
        let errand: BotErrand

        func submittedCount() -> Int { script.submitted.withLock { $0.count } }

        func waitForSubmission() async throws {
            try await waitUntil("a prompt.submit", timeout: .seconds(10)) { submittedCount() >= 1 }
        }

        func turn(from sequence: Int, reply: String) {
            gateway.push(script.event("message.start", seq: sequence, payload: [:]))
            gateway.push(script.event("message.delta", seq: sequence + 1, payload: ["text": .string(reply), "segment": 0, "offset": 0]))
            gateway.push(script.event("message.complete", seq: sequence + 2, payload: ["text": .string(reply)]))
        }

        func finish() async {
            await hub.release(session)
            gateway.stop()
        }
    }

    private func rig(
        configure: (BotScript) -> Void = { _ in },
        failConnects: @escaping @Sendable (Int) -> (any Error)? = { _ in nil },
        connectTimeout: Duration = .seconds(5)
    ) async throws -> Rig {
        let script = BotScript()
        configure(script)
        let gateway = try await FakeGateway.start(script.handle)
        let connector = ScriptedConnector(url: gateway.url, failure: failConnects)
        let hub = SessionHub(profile: "bot", connector: connector)
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: hub)
        let session = await hub.acquire()
        let errand = BotErrand(botID: "bot", session: session, outbox: outbox, connectTimeout: connectTimeout)
        return Rig(script: script, gateway: gateway, connector: connector, hub: hub, outbox: outbox, session: session, errand: errand)
    }

    @Test func askReturnsTheReplyOnceTheTurnCompletes() async throws {
        let rig = try await rig()
        let asking = Task { try await rig.errand.ask("hello", deadline: .seconds(10)) }
        try await rig.waitForSubmission()
        rig.turn(from: 2, reply: "hi from the bot")
        #expect(try await asking.value == .replied("hi from the bot"))
        #expect(rig.submittedCount() == 1)
        await rig.finish()
    }

    @Test func askPastTheDeadlineIsStillWorkingAndTheTurnIsNotLost() async throws {
        let rig = try await rig()
        let outcome = try await rig.errand.ask("slow one", deadline: .milliseconds(300))
        #expect(outcome == .stillWorking)
        rig.turn(from: 2, reply: "late answer")
        try await waitUntil("the late reply to land in the shared session") {
            await rig.session.state.transcript.assistantTexts == ["late answer"]
        }
        #expect(rig.submittedCount() == 1)
        await rig.finish()
    }

    @Test func aClarifyQuestionRaisedMidTurnComesBackAsNeedsInput() async throws {
        let rig = try await rig()
        let asking = Task { try await rig.errand.ask("pick for me", deadline: .seconds(10)) }
        try await rig.waitForSubmission()
        rig.gateway.push(rig.script.event("message.start", seq: 2, payload: [:]))
        rig.gateway.push(rig.script.event("clarify.request", seq: 3, payload: [
            "kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?", "choices": ["a", "b"],
        ]))
        guard case .needsInput(let prompt) = try await asking.value else {
            Issue.record("expected needsInput")
            return
        }
        #expect(prompt.question == "Which flavor?")
        await rig.finish()
    }

    @Test func askingABotThatWaitsOnAnAnswerRelaysItsQuestionInsteadOfQueueingBehindIt() async throws {
        let rig = try await rig(configure: { script in
            script.override("session.resume") { _ in .result(BotScript().snapshotWithPrompt) }
        })
        let outcome = try await rig.errand.ask("are you there", deadline: .seconds(10))
        guard case .needsInput(let prompt) = outcome else {
            Issue.record("expected needsInput, got \(outcome)")
            return
        }
        #expect(prompt.promptID == "p1")
        #expect(rig.submittedCount() == 0, "nothing is queued behind the unanswered question")
        #expect(await rig.outbox.snapshot(botID: "bot").isEmpty)
        await rig.finish()
    }

    @Test(arguments: ["permission_denied", "profile_mismatch"])
    func aPermanentGatewayRefusalFailsTheErrandAndKeepsTheFailedEntry(reason: String) async throws {
        let rig = try await rig(configure: { script in
            script.override("prompt.submit") { _ in .failure(RPCError(code: 4001, message: reason, data: ["reason": .string(reason)])) }
        })
        await #expect(throws: ErrandError.refused(reason: reason)) { try await rig.errand.tell("refuse me") }
        let stored = await rig.outbox.snapshot(botID: "bot")
        #expect(stored.map(\.state) == [.failed(reason: reason)])
        await rig.finish()
    }

    @Test func aTransientFailureIsUnreachableAndLeavesNothingToSendLater() async throws {
        let rig = try await rig(configure: { script in
            script.override("prompt.submit") { _ in .failure(RPCError(code: -32603, message: "database is locked")) }
        })
        await #expect(throws: ErrandError.unreachable) { try await rig.errand.tell("try later") }
        #expect(await rig.outbox.snapshot(botID: "bot").isEmpty)
        await rig.finish()
    }

    @Test func anUnreachableGatewayNeverQueuesTheMessage() async throws {
        let rig = try await rig(failConnects: { _ in GatewayTransportError.closed(.lost) })
        await #expect(throws: ErrandError.unreachable) { try await rig.errand.ask("anyone there", deadline: .seconds(1)) }
        #expect(await rig.outbox.snapshot(botID: "bot").isEmpty)
        #expect(rig.submittedCount() == 0)
        await rig.finish()
    }

    @Test func anExpiredSessionAsksForSignIn() async throws {
        let rig = try await rig(failConnects: { _ in RESTError.unauthorized })
        await #expect(throws: ErrandError.signInRequired) { try await rig.errand.tell("hello") }
        await rig.finish()
    }

    @Test func tellReturnsOnAdmissionWithoutWaitingForTheReply() async throws {
        let rig = try await rig()
        let started = ContinuousClock.now
        let mark = try await rig.errand.tell("fire and forget")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(rig.submittedCount() == 1)
        #expect(await rig.outbox.snapshot(botID: "bot").first?.submissionID == mark.submissionID)
        rig.turn(from: 2, reply: "done later")
        try await waitUntil("the reply") { await rig.session.state.transcript.errandOutcome(for: mark) == .replied("done later") }
        await rig.finish()
    }

    @Test func aChatScreenDrainingTheOutboxAtTheSameTimeStillAdmitsExactlyOnce() async throws {
        let rig = try await rig()
        let draining = Task {
            while !Task.isCancelled {
                _ = await rig.outbox.deliverPending(botID: "bot")
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        for index in 0..<5 { _ = try await rig.errand.tell("message \(index)") }
        draining.cancel()
        #expect(rig.submittedCount() == 5)
        let ids = rig.script.submitted.withLock { $0.compactMap { $0["submission_id"]?.stringValue } }
        #expect(Set(ids).count == 5)
        await rig.finish()
    }

    @Test func aReconnectMidTurnStillSettlesFromTheReloadedSnapshot() async throws {
        let rig = try await rig()
        let asking = Task { try await rig.errand.ask("question across a drop", deadline: .seconds(20)) }
        try await rig.waitForSubmission()
        rig.script.messages.withLock { $0 = [("user", "question across a drop"), ("assistant", "answer after the drop")] }
        rig.script.lastSequence.withLock { $0 = 6 }
        rig.gateway.dropAll()
        #expect(try await asking.value == .replied("answer after the drop"))
        #expect(rig.connector.dialed.count >= 2)
        await rig.finish()
    }

    @Test func cancellingTheErrandWhileItWaitsReturnsPromptlyAndDropsTheWaiter() async throws {
        let rig = try await rig()
        let asking = Task { try await rig.errand.ask("never answered", deadline: .seconds(60)) }
        try await rig.waitForSubmission()
        asking.cancel()
        let started = ContinuousClock.now
        _ = try? await asking.value
        #expect(ContinuousClock.now - started < .seconds(5))
        await rig.finish()
    }
}

@Suite("Session hub")
struct SessionHubTests {
    @Test func holdersShareOneSessionAndTheLastReleaseClosesIt() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let hub = SessionHub(profile: "bot", connector: ScriptedConnector(url: gateway.url))
        let first = await hub.acquire()
        let second = await hub.acquire()
        #expect(first === second)
        try await first.start()
        await hub.release(first)
        guard case .live = await first.phase else {
            Issue.record("one holder left, the session must stay live")
            return
        }
        await hub.release(second)
        #expect(await first.phase == .detached)
        let next = await hub.acquire()
        #expect(next !== first)
        await hub.release(next)
    }

    @Test func submitWithoutAHolderIsRetryableNotPermanent() async throws {
        let hub = SessionHub(profile: "bot", connector: ScriptedConnector(url: URL(string: "ws://127.0.0.1:1")!))
        let entry = OutboxEntry(
            submissionID: "s", botID: "bot", text: "t", attachments: [], createdAt: Date(), state: .pending, attempts: 0
        )
        await #expect(throws: ChatError.notConnected) { _ = try await hub.submit(entry, files: []) }
    }
}
