import Foundation
import PalChat
import PalProtocol
import PalTransport
import Testing

enum CardFixture {
    static let deadline = Date().timeIntervalSince1970 + 600

    static func target(
        _ name: String = "fixture-server",
        state: String = "failed",
        kind: String = "mcp",
        action: String = "enable",
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name), "kind": .string(kind), "action": .string(action), "state": .string(state),
            "resolved": .bool(state == "connected" || state == "skipped" || state == "declined"),
        ]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    static func request(opID: String = "op-1", seq: Int = 1, targets: [JSONValue]? = nil) -> JSONValue {
        [
            "op_id": .string(opID),
            "seq": .int(seq),
            "deadline_at": .double(deadline),
            "timeout_seconds": 600,
            "tool_call_id": "call-1",
            "targets": .array(targets ?? [target()]),
        ]
    }

    static func update(
        opID: String = "op-1",
        seq: Int,
        targets: [JSONValue],
        settledBy: String? = nil,
        session: String = "s1"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "op_id": .string(opID),
            "seq": .int(seq),
            "deadline_at": .double(deadline),
            "settled": .bool(settledBy != nil),
            "targets": .array(targets),
            "owner": ["type": "session", "session_id": .string(session)],
        ]
        if let settledBy {
            object["settled_at"] = .double(Date().timeIntervalSince1970)
            object["settled_by"] = .string(settledBy)
        }
        return .object(object)
    }

    static func toolResult(opID: String = "op-1", seq: Int, state: String) -> String {
        let object: JSONValue = [
            "op_id": .string(opID),
            "seq": .int(seq),
            "deadline_at": .double(deadline),
            "settled_at": .double(Date().timeIntervalSince1970),
            "settled_by": "all_resolved",
            "targets": [target(state: state)],
            "status": "settled",
            "note": "The operation settled.",
        ]
        return String(decoding: (try? JSONEncoder().encode(object)) ?? Data(), as: UTF8.self)
    }

    static func snapshot(
        messages: [JSONValue] = [],
        lastSequence: Int = 1,
        pendingConnection: JSONValue? = nil,
        epoch: String = "e1"
    ) throws -> SessionSnapshot {
        var object: [String: JSONValue] = [
            "session_id": "s1",
            "messages": .array(messages),
            "running": false,
            "replay_epoch": .string(epoch),
            "last_sequence": .int(lastSequence),
            "execution_generation": 1,
            "pending": [],
            "prompts": [],
        ]
        if let pendingConnection { object["pending_connection"] = pendingConnection }
        return try JSONValue.object(object).decoded(as: SessionSnapshot.self)
    }

    static func frame(_ type: String, _ payload: JSONValue, seq: Int, session: String = "s1") -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: session, seq: seq, replayEpoch: "e1")
    }
}

private func shownCards(_ chat: ChatSession) async -> [ConnectionCard] {
    await chat.timelineSnapshot.rows.compactMap { row in
        if case .connection(let card) = row.item.content { return card }
        return nil
    }
}

private func shownCard(_ chat: ChatSession, opID: String) async -> ConnectionCard? {
    await shownCards(chat).first { $0.operation.opID == opID }
}

private func shownPending(_ chat: ChatSession) async -> [ConnectionCard] {
    await shownCards(chat).filter { $0.isActionable(now: Date()) }
}

func cardsOf(_ transcript: Transcript) -> [ConnectionCard] {
    transcript.items.compactMap { item in
        if case .connection(let card) = item.content { return card }
        return nil
    }
}

func stateOf(_ card: ConnectionCard?) -> ConnectionTargetState? {
    card?.operation.targets.first { $0.name == "fixture-server" }?.state
}

@Suite("Connection operation cards in the transcript")
struct ConnectionTranscriptTests {
    private func opened(_ payload: JSONValue = CardFixture.request()) throws -> Transcript {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try CardFixture.snapshot())
        #expect(transcript.apply(CardFixture.frame("connection.request", payload, seq: 2)) == .applied)
        return transcript
    }

    @Test func aFailedRequestOpensOneCardOfferingOnlyTryAgain() throws {
        let transcript = try opened()
        let card = try #require(cardsOf(transcript).first)
        #expect(cardsOf(transcript).count == 1)
        #expect(transcript.items.last?.id == "connection:op-1")
        #expect(transcript.summary().items.last?.kind == "connection")
        let target = try #require(card.operation.targets.first)
        #expect(card.decisions(for: target, now: Date()) == [.tryAgain])
        #expect(transcript.pendingConnections().count == 1)
        #expect(transcript.pendingPrompts.isEmpty)
    }

    @Test func aHigherSeqUpdateMovesAndSettlesTheSameCard() throws {
        var transcript = try opened()
        let connected = CardFixture.target(state: "connected", extra: ["tools": ["alpha", "beta"]])
        _ = transcript.apply(CardFixture.frame("connection.update", CardFixture.update(seq: 4, targets: [connected], settledBy: "all_resolved"), seq: 3))
        let all = cardsOf(transcript)
        #expect(all.count == 1)
        let card = try #require(all.first)
        #expect(stateOf(card) == .connected)
        #expect(card.operation.settled)
        #expect(card.operation.settledBy == .allResolved)
        #expect(card.operation.targets.first?.tools == ["alpha", "beta"])
        #expect(card.decisions(for: try #require(card.operation.targets.first), now: Date()).isEmpty)
        #expect(transcript.pendingConnections().isEmpty)
    }

    @Test func anUpdateForAnUnknownOperationInsertsItsSnapshot() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try CardFixture.snapshot())
        _ = transcript.apply(CardFixture.frame("connection.update", CardFixture.update(seq: 3, targets: [CardFixture.target(state: "initiated")]), seq: 2))
        #expect(stateOf(cardsOf(transcript).first) == .initiated)
    }

    @Test(arguments: [3, 2])
    func anUpdateWhoseSeqIsNotHigherMovesNothing(staleSeq: Int) throws {
        var transcript = try opened(CardFixture.request(seq: 3))
        _ = transcript.apply(CardFixture.frame(
            "connection.update", CardFixture.update(seq: staleSeq, targets: [CardFixture.target(state: "skipped")], settledBy: "all_resolved"), seq: 3
        ))
        let card = try #require(cardsOf(transcript).first)
        #expect(stateOf(card) == .failed)
        #expect(!card.operation.settled)
    }

    @Test func anUpdateForAnotherSessionIsIgnored() throws {
        var transcript = try opened()
        _ = transcript.apply(CardFixture.frame(
            "connection.update", CardFixture.update(seq: 5, targets: [CardFixture.target(state: "skipped")], session: "other"), seq: 3
        ))
        #expect(stateOf(cardsOf(transcript).first) == .failed)
        var empty = Transcript()
        _ = empty.reconcile(with: try CardFixture.snapshot())
        _ = empty.apply(CardFixture.frame("connection.update", CardFixture.update(seq: 5, targets: [CardFixture.target()], session: "other"), seq: 2))
        #expect(cardsOf(empty).isEmpty)
    }

    @Test func aReplayedRequestDoesNotDuplicateTheCard() throws {
        var transcript = try opened()
        _ = transcript.apply(CardFixture.frame("connection.request", CardFixture.request(), seq: 3))
        _ = transcript.apply(CardFixture.frame("connection.request", CardFixture.request(seq: 1), seq: 4))
        #expect(cardsOf(transcript).count == 1)
    }

    @Test func twoOperationsKeepTwoCards() throws {
        var transcript = try opened()
        _ = transcript.apply(CardFixture.frame("connection.request", CardFixture.request(opID: "op-2", targets: [CardFixture.target("other-server")]), seq: 3))
        #expect(cardsOf(transcript).map(\.operation.opID) == ["op-1", "op-2"])
    }

    @Test func aResumeWithAPendingConnectionRestoresExactlyOneCard() throws {
        var transcript = Transcript()
        let snapshot = try CardFixture.snapshot(lastSequence: 7, pendingConnection: CardFixture.request(seq: 2))
        _ = transcript.reconcile(with: snapshot)
        _ = transcript.reconcile(with: snapshot)
        transcript.load(snapshot)
        #expect(cardsOf(transcript).count == 1)
        #expect(cardsOf(transcript).first?.lapsed == false)
        #expect(transcript.pendingConnections().count == 1)
    }

    @Test func aResumeWithoutTheOperationLapsesAnOpenCard() throws {
        var transcript = try opened()
        #expect(transcript.reconcile(with: try CardFixture.snapshot(lastSequence: 2)) == false)
        let card = try #require(cardsOf(transcript).first)
        #expect(card.lapsed)
        #expect(!card.isOpen(now: Date()))
        #expect(transcript.pendingConnections().isEmpty)
    }

    @Test func aResumeKeepsTheOpenCardWhenTheBackendStillHoldsIt() throws {
        var transcript = try opened()
        _ = transcript.reconcile(with: try CardFixture.snapshot(lastSequence: 2, pendingConnection: CardFixture.request()))
        #expect(cardsOf(transcript).count == 1)
        #expect(cardsOf(transcript).first?.lapsed == false)
    }

    @Test func aResumeNeverReopensASettledCard() throws {
        var transcript = try opened()
        _ = transcript.apply(CardFixture.frame(
            "connection.update", CardFixture.update(seq: 4, targets: [CardFixture.target(state: "skipped")], settledBy: "all_resolved"), seq: 3
        ))
        _ = transcript.reconcile(with: try CardFixture.snapshot(lastSequence: 3))
        let card = try #require(cardsOf(transcript).first)
        #expect(card.operation.settled)
        #expect(!card.lapsed)
    }

    @Test func aHistoryToolRowRestoresASettledCardAndToolCompleteDoesNotDuplicateIt() throws {
        let row: JSONValue = [
            "role": "tool", "name": "manage_connections", "tool_call_id": "call-1", "row_id": 1,
            "content": .string(CardFixture.toolResult(seq: 6, state: "connected")),
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try CardFixture.snapshot(messages: [row]))
        let restored = try #require(cardsOf(transcript).first)
        #expect(restored.operation.settled)
        #expect(stateOf(restored) == .connected)
        #expect(transcript.items.filter { if case .tool = $0.content { true } else { false } }.isEmpty)
        let complete: JSONValue = [
            "tool_id": "call-1", "name": "manage_connections", "result": .string(CardFixture.toolResult(seq: 6, state: "connected")),
        ]
        _ = transcript.apply(CardFixture.frame("tool.complete", complete, seq: 2))
        #expect(cardsOf(transcript).count == 1)
        transcript.load(try CardFixture.snapshot(messages: [row], lastSequence: 2))
        #expect(cardsOf(transcript).count == 1)
    }

    @Test func aLiveToolResultSettlesTheOpenCard() throws {
        var transcript = try opened()
        let complete: JSONValue = [
            "tool_id": "call-1", "name": "manage_connections", "result": .string(CardFixture.toolResult(seq: 5, state: "skipped")),
        ]
        _ = transcript.apply(CardFixture.frame("tool.complete", complete, seq: 3))
        let card = try #require(cardsOf(transcript).first)
        #expect(cardsOf(transcript).count == 1)
        #expect(card.operation.settled)
        #expect(stateOf(card) == .skipped)
        #expect(transcript.items.contains { $0.id == "tool:call-1" })
    }

    @Test func aMalformedPendingConnectionDoesNotBreakTheResume() throws {
        let snapshot = try CardFixture.snapshot(pendingConnection: ["op_id": 7, "targets": "nope"])
        #expect(snapshot.pendingConnection == nil)
        #expect(snapshot.sessionID == "s1")
    }

    @Test func aNewerBackendStateStillDecodesAndOffersNoDecision() throws {
        var transcript = try opened(CardFixture.request(targets: [CardFixture.target(state: "quarantined")]))
        let card = try #require(cardsOf(transcript).first)
        #expect(stateOf(card)?.rawValue == "quarantined")
        #expect(card.decisions(for: try #require(card.operation.targets.first), now: Date()).isEmpty)
        _ = transcript.apply(CardFixture.frame(
            "connection.update", CardFixture.update(seq: 4, targets: [CardFixture.target(state: "connected")], settledBy: "something_new"), seq: 3
        ))
        #expect(cardsOf(transcript).first?.operation.settledBy?.rawValue == "something_new")
    }

    @Test func actionabilityFollowsStateAndTheClock() throws {
        let transcript = try opened(CardFixture.request(targets: [
            CardFixture.target("a-server", state: "pending"),
            CardFixture.target("b-server", state: "failed"),
            CardFixture.target("c-server", state: "expired"),
            CardFixture.target("d-server", state: "connected"),
            CardFixture.target("e-server", state: "initiated"),
            CardFixture.target("f-app", state: "pending", kind: "connector", action: "authorize"),
            CardFixture.target("g-server", state: "declined"),
        ]))
        let card = try #require(cardsOf(transcript).first)
        let now = Date()
        let byName = Dictionary(uniqueKeysWithValues: card.operation.targets.map { ($0.name, card.decisions(for: $0, now: now)) })
        #expect(byName["a-server"] == [])
        #expect(byName["b-server"] == [.tryAgain])
        #expect(byName["c-server"] == [.tryAgain])
        #expect(byName["d-server"] == [])
        #expect(byName["e-server"] == [])
        #expect(byName["f-app"] == [])
        #expect(byName["g-server"] == [])
        let late = card.operation.deadlineAt.addingTimeInterval(1)
        #expect(card.operation.targets.allSatisfy { card.decisions(for: $0, now: late).isEmpty })
        #expect(!card.isActionable(now: late))
    }

    @Test func clarifyAndApprovalCardsAreUnaffected() throws {
        var transcript = try opened()
        let clarify: JSONValue = ["kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?", "choices": ["a", "b"]]
        let approval: JSONValue = [
            "kind": "approval", "prompt_id": "p2", "execution_generation": 1, "question": "Send this message?", "command": "hi",
            "draft": ["text": "hi"], "choices": ["once", "deny"],
        ]
        _ = transcript.apply(CardFixture.frame("clarify.request", clarify, seq: 3))
        _ = transcript.apply(CardFixture.frame("approval.request", approval, seq: 4))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["p1", "p2"])
        _ = transcript.apply(CardFixture.frame("clarify.settled", ["prompt_id": "p1"], seq: 5))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["p2"])
        #expect(cardsOf(transcript).count == 1)
        #expect(transcript.summary().items.map(\.kind) == ["connection", "clarify"])
    }
}

@Suite("Connection cards through a chat session", .serialized)
struct ConnectionChatSessionTests {
    private func session(_ connector: ScriptedConnector) -> ChatSession {
        ChatSession(
            profile: "bot",
            connector: connector,
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(20), maximumDelay: .milliseconds(80))
        )
    }

    private func openCard(_ chat: ChatSession, _ gateway: FakeGateway, _ script: BotScript, seq: Int = 2) async throws {
        gateway.push(script.event("connection.request", seq: seq, payload: CardFixture.request()), to: 0)
        try await waitUntil("the connection card", timeout: .seconds(5)) {
            await !shownCards(chat).isEmpty
        }
    }

    @Test func connectionRequestReachesAnActivationCardInTheTranscript() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        let pending = await shownPending(chat)
        #expect(pending.map(\.operation.opID) == ["op-1"])
        await chat.close()
    }

    @Test func tryAgainSendsOneApprovedTargetBoundToTheSessionAndOperation() async throws {
        let script = BotScript()
        script.override("connection.respond") { _ in .result(["status": "ok", "settled": false]) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        gateway.push(script.event("connection.request", seq: 2, payload: CardFixture.request(targets: [
            CardFixture.target("fixture-server"), CardFixture.target("second-server"),
        ])), to: 0)
        try await waitUntil("the connection card", timeout: .seconds(5)) { await shownPending(chat).count == 1 }
        try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        let expected: JSONValue = [
            "owner": ["type": "session", "session_id": "s1"],
            "op_id": "op-1",
            "profile": "bot",
            "result": ["targets": [["name": "fixture-server", "status": "approved"]]],
        ]
        #expect(script.calls("connection.respond") == [expected])
        await chat.close()
    }

    @Test func aPendingRowRefusesAnyAnswerWithoutACall() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        gateway.push(script.event("connection.request", seq: 2, payload: CardFixture.request(targets: [CardFixture.target(state: "pending")])), to: 0)
        try await waitUntil("the connection card", timeout: .seconds(5)) { await !shownCards(chat).isEmpty }
        #expect(await shownPending(chat).isEmpty)
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        }
        #expect(script.count("connection.respond") == 0)
        await chat.close()
    }

    @Test func answersTheCardCannotActOnAreRefusedWithoutAnyCall() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(opID: "op-1", target: "missing-server", decision: .tryAgain)
        }
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(opID: "no-such-op", target: "fixture-server", decision: .tryAgain)
        }
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(
                opID: "op-1", target: "fixture-server", decision: .tryAgain, now: Date(timeIntervalSince1970: CardFixture.deadline + 1)
            )
        }
        gateway.push(script.event("connection.update", seq: 3, payload: CardFixture.update(
            seq: 5, targets: [CardFixture.target(state: "declined")], settledBy: "all_resolved"
        )), to: 0)
        try await waitUntil("the settled card", timeout: .seconds(5)) { await shownPending(chat).isEmpty }
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        }
        #expect(script.count("connection.respond") == 0)
        await chat.close()
    }

    @Test func aLapsedCardCannotBeAnswered() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        script.lastSequence.withLock { $0 = 2 }
        gateway.dropAll()
        try await waitUntil("the lapsed card", timeout: .seconds(10)) {
            await shownCard(chat, opID: "op-1")?.lapsed == true
        }
        await #expect(throws: ChatError.connectionNotActionable) {
            try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        }
        #expect(script.count("connection.respond") == 0)
        await chat.close()
    }

    @Test func aGatewayRefusalOfAnUnknownOperationLapsesTheCard() async throws {
        let script = BotScript()
        script.override("connection.respond") { _ in
            .failure(RPCError(code: 4004, message: "No open operation with that op_id.", data: ["reason": "unknown_operation"]))
        }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        await #expect(throws: GatewayTransportError.self) {
            try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        }
        let card = try #require(await shownCard(chat, opID: "op-1"))
        #expect(card.lapsed)
        #expect(await shownPending(chat).isEmpty)
        #expect(script.count("connectors.operation.status") == 0)
        await chat.close()
    }

    @Test func anyOtherRefusalFetchesTheStatusAndAppliesIt() async throws {
        let script = BotScript()
        script.override("connection.respond") { _ in
            .failure(RPCError(code: 4002, message: "Connection answer is invalid.", data: ["reason": "invalid_answer"]))
        }
        script.override("connectors.operation.status") { _ in
            .result(CardFixture.update(seq: 6, targets: [CardFixture.target(state: "connected")], settledBy: "all_resolved"))
        }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        await #expect(throws: GatewayTransportError.self) {
            try await chat.answerConnection(opID: "op-1", target: "fixture-server", decision: .tryAgain)
        }
        let card = try #require(await shownCard(chat, opID: "op-1"))
        #expect(card.operation.settled)
        #expect(stateOf(card) == .connected)
        let status = try #require(script.calls("connectors.operation.status").first)
        #expect(status == ["owner": ["type": "session", "session_id": "s1"], "op_id": "op-1", "profile": "bot"])
        await chat.close()
    }

    @Test func aReconnectRestoresTheCardFromThePendingConnectionOfTheResume() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        try await openCard(chat, gateway, script)
        script.lastSequence.withLock { $0 = 2 }
        script.override("session.resume") { _ in
            var object = script.snapshot.objectValue ?? [:]
            object["pending_connection"] = CardFixture.request()
            return .result(.object(object))
        }
        gateway.dropAll()
        try await waitUntil("a reconnect", timeout: .seconds(10)) { script.count("session.resume") >= 2 }
        try await waitUntil("a live phase", timeout: .seconds(10)) {
            if case .live = await chat.phase { true } else { false }
        }
        let all = await chat.timelineSnapshot.rows.filter { $0.item.id == "connection:op-1" }
        #expect(all.count == 1)
        #expect(await shownPending(chat).count == 1)
        await chat.close()
    }
}
