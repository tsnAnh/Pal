import Foundation
import HermesChat
import HermesProtocol
import Testing

private struct Feed {
    var transcript = Transcript()
    private(set) var frames: [SessionEventFrame] = []
    private(set) var sequence = 0

    init(history: [(role: String, text: String)] = [], running: Bool = true, lastSequence: Int = 0) throws {
        sequence = lastSequence
        _ = transcript.reconcile(with: try Self.snapshot(history, running: running, lastSequence: lastSequence))
    }

    static func snapshot(_ history: [(role: String, text: String)], running: Bool, lastSequence: Int) throws -> SessionSnapshot {
        let rows: [JSONValue] = history.enumerated().map { index, row in
            .object(["role": .string(row.role), "text": .string(row.text), "row_id": .int(index + 1)])
        }
        let object: JSONValue = [
            "session_id": "s1",
            "messages": .array(rows),
            "running": .bool(running),
            "replay_epoch": "e1",
            "last_sequence": .int(lastSequence),
            "execution_generation": 1,
            "pending": [],
            "prompts": [],
        ]
        return try object.decoded(as: SessionSnapshot.self)
    }

    @discardableResult
    mutating func send(_ type: String, _ payload: JSONValue = [:]) -> ApplyOutcome {
        sequence += 1
        let frame = SessionEventFrame(
            event: SessionEvent(type: type, payload: payload),
            sessionID: "s1",
            seq: sequence,
            replayEpoch: "e1",
            executionGeneration: 1
        )
        frames.append(frame)
        return transcript.apply(frame)
    }

    mutating func start(_ turn: String = "t1") { send("message.start", ["turn_id": .string(turn)]) }

    mutating func delta(_ text: String, segment: Int = 0, offset: Int = 0, turn: String = "t1") {
        send("message.delta", ["text": .string(text), "segment": .int(segment), "offset": .int(offset), "turn_id": .string(turn)])
    }

    mutating func queued(_ text: String, input: String, status: String = "queued") {
        let admission: JSONValue = [
            "admission_id": .string("a-\(input)"), "status": .string(status), "input_id": .string(input), "text": .string(text),
        ]
        send("session.info", ["running": true, "pending": [admission]])
    }

    mutating func absorbed(_ admissions: [String], text: String, turn: String = "t1", uid: String = "m-1") {
        send("input.absorbed", [
            "turn_id": .string(turn),
            "admission_ids": .array(admissions.map(JSONValue.string)),
            "message_uid": .string(uid),
            "text": .string(text),
        ])
    }

    mutating func complete(_ text: String) { send("message.complete", ["text": .string(text)]) }
}

private extension Transcript {
    var conversation: [String] { summary().conversation.map { "\($0.kind): \($0.text)" } }

    var userDeliveries: [(text: String, delivery: TranscriptItem.Delivery)] {
        items.compactMap { item in
            if case .user(let text, let delivery) = item.content { (text, delivery) } else { nil }
        }
    }
}

@Suite("Input absorbed into a running turn")
struct InputAbsorbedTests {
    @Test(arguments: [(0, 14), (1, 0)])
    func theOwnerBubbleSitsBetweenTheTwoSegmentsOfOneTurn(segment: Int, offset: Int) throws {
        var feed = try Feed(history: [("user", "merge everything")])
        feed.start()
        feed.delta("Merging the PRs. ")
        feed.queued("also weather in Hanoi?", input: "i1")
        feed.absorbed(["a-i1"], text: "also weather in Hanoi?")
        feed.delta("24 degrees and clear.", segment: segment, offset: offset)
        feed.complete("24 degrees and clear.")
        #expect(feed.transcript.conversation == [
            "user: merge everything",
            "assistant: Merging the PRs. ",
            "user: also weather in Hanoi?",
            "assistant: 24 degrees and clear.",
        ])
        #expect(feed.transcript.userDeliveries.map(\.delivery) == [.sent, .sent])
        #expect(!feed.transcript.isRunning)
    }

    @Test func theTurnKeepsRunningThroughTheAbsorb() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a1"], text: "hurry")
        #expect(feed.transcript.isRunning)
        #expect(feed.transcript.items.compactMap { item -> Bool? in
            if case .assistant(_, _, let streaming) = item.content { streaming } else { nil }
        } == [false])
    }

    @Test func queuedEchoBelowTheStreamDoesNotSplitIt() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("a")
        feed.queued("later", input: "i1")
        feed.delta("b", offset: 1)
        feed.complete("ab")
        let ids = feed.transcript.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(feed.transcript.assistantTexts == ["ab"])
    }

    @Test func absorbedBeforeAnyMessageStartStillPlacesTheBubbleAndOpensANewSegment() throws {
        var feed = try Feed(history: [("user", "go"), ("assistant", "first part")], lastSequence: 4)
        feed.absorbed(["a1"], text: "hurry")
        feed.delta("second part", offset: 10)
        #expect(feed.transcript.isRunning)
        feed.complete("second part")
        #expect(feed.transcript.conversation == [
            "user: go", "assistant: first part", "user: hurry", "assistant: second part",
        ])
    }

    @Test func absorbedWithoutALocalEchoInsertsTheOwnerTextWhereItLanded() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a1"], text: "from my phone", uid: "m-9")
        let inserted = try #require(feed.transcript.items.last)
        #expect(inserted.content == .user(text: "from my phone", delivery: .sent))
        #expect(inserted.uid == "m-9")
        #expect(feed.transcript.conversation == ["user: go", "assistant: working", "user: from my phone"])
    }

    @Test func aLocalEchoWithTheSameTextIsConfirmedNotDuplicated() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.transcript.echoUser(submissionID: "s1", text: "also this")
        feed.absorbed(["adm-9"], text: "also this")
        #expect(feed.transcript.userDeliveries.map(\.text) == ["go", "also this"])
        let echo = try #require(feed.transcript.items.first { $0.id == "submission:s1" })
        #expect(echo.content == .user(text: "also this", delivery: .sent))
        #expect(feed.transcript.items.last?.id == "submission:s1")
    }

    @Test func anUnrelatedUnsentEchoStaysUnsent() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.transcript.echoUser(submissionID: "s2", text: "other thing")
        feed.transcript.echoUser(submissionID: "s1", text: "also this")
        feed.absorbed(["adm-9"], text: "also this")
        let deliveries = Dictionary(uniqueKeysWithValues: feed.transcript.userDeliveries.map { ($0.text, $0.delivery) })
        #expect(deliveries["also this"] == .sent)
        #expect(deliveries["other thing"] == .sending)
    }

    @Test func twoAdmissionsInOneEventKeepSubmissionOrder() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.queued("one", input: "i1")
        feed.queued("two", input: "i2")
        feed.absorbed(["a-i1", "a-i2"], text: "one\n\ntwo")
        feed.delta("done", offset: 7)
        #expect(feed.transcript.conversation == [
            "user: go", "assistant: working", "user: one", "user: two", "assistant: done",
        ])
        #expect(feed.transcript.userDeliveries.map(\.delivery) == [.sent, .sent, .sent])
    }

    @Test func twoAdmissionsWithoutLocalEchoesBecomeOneRowLikeTheServerWroteIt() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a1", "a2"], text: "one\n\ntwo")
        #expect(feed.transcript.conversation == ["user: go", "assistant: working", "user: one\n\ntwo"])
    }

    @Test func aReplayedFrameChangesNothing() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a1"], text: "hurry")
        let before = feed.transcript
        let replayed = try #require(feed.frames.last)
        let outcome = feed.transcript.apply(replayed)
        #expect(outcome == .duplicate)
        #expect(feed.transcript == before)
    }

    @Test func absorbingTheSameAdmissionAgainAddsNoSecondBubble() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a1"], text: "hurry")
        feed.absorbed(["a1"], text: "hurry")
        #expect(feed.transcript.userDeliveries.map(\.text) == ["go", "hurry"])
    }

    @Test func laterAdmissionInfoForAnAbsorbedInputAddsNoSecondBubble() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.absorbed(["a-i1"], text: "hurry")
        feed.delta(" more", offset: 7)
        feed.queued("hurry", input: "i1", status: "started")
        feed.complete("working more")
        #expect(feed.transcript.userDeliveries.map(\.text) == ["go", "hurry"])
    }

    @Test func resumingMidTurnRebuildsTheSameOrderAsTheLiveStream() throws {
        var live = try Feed(history: [("user", "go")])
        live.start()
        live.delta("first part")
        live.absorbed(["a1"], text: "hurry")
        live.delta("second part", offset: 10)
        live.complete("second part")

        var resumed = try Feed(history: [("user", "go"), ("assistant", "first part")], lastSequence: 2)
        for frame in live.frames.dropFirst(2) { _ = resumed.transcript.apply(frame) }
        #expect(resumed.transcript.conversation == live.transcript.conversation)
        #expect(resumed.transcript.userDeliveries.map(\.delivery) == live.transcript.userDeliveries.map(\.delivery))
    }

    @Test func reconnectingMidTurnReplacesTheTranscriptWithoutADuplicateBubble() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("first part")
        feed.absorbed(["a1"], text: "hurry")
        feed.delta("second", offset: 10)
        feed.transcript.requestResync()
        let server = try Feed.snapshot(
            [("user", "go"), ("assistant", "first part"), ("user", "hurry"), ("assistant", "second so far")],
            running: true,
            lastSequence: 6
        )
        let replaced = feed.transcript.reconcile(with: server)
        #expect(replaced)
        #expect(feed.transcript.conversation == [
            "user: go", "assistant: first part", "user: hurry", "assistant: second so far",
        ])
        #expect(feed.transcript.isRunning)
    }

    @Test func aResyncDropsTheStreamingSegmentEvenWhenAnEchoSitsBelowIt() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("partial")
        feed.queued("later", input: "i1")
        feed.transcript.requestResync()
        #expect(feed.transcript.assistantTexts.isEmpty)
        #expect(feed.transcript.userDeliveries.map(\.text) == ["go", "later"])
    }

    @Test func anOldServerThatNeverAbsorbsKeepsTheQueuedOrder() throws {
        var feed = try Feed(history: [("user", "go")])
        feed.start()
        feed.delta("working")
        feed.queued("later", input: "i1")
        feed.complete("working")
        feed.start("t2")
        feed.queued("later", input: "i1", status: "started")
        feed.delta("reply")
        feed.complete("reply")
        #expect(feed.transcript.conversation == ["user: go", "assistant: working", "user: later", "assistant: reply"])
    }

    @Test func anErrandKeepsCollectingRepliesAcrossAnAbsorbedOwnerBubble() throws {
        var feed = try Feed(history: [], running: false)
        feed.transcript.echoUser(submissionID: "s1", text: "merge everything")
        feed.start()
        feed.delta("Merging.")
        feed.absorbed(["a2"], text: "also weather?")
        feed.delta("Clear skies.", segment: 1)
        feed.complete("Clear skies.")
        let mark = ErrandMark(submissionID: "s1", text: "merge everything", userItemsBefore: 0)
        #expect(feed.transcript.errandOutcome(for: mark) == .replied("Merging.\n\nClear skies."))
    }

    @Test func anErrandIsNotFinishedWhileTheTurnStillRunsAfterTheAbsorb() throws {
        var feed = try Feed(history: [], running: false)
        feed.transcript.echoUser(submissionID: "s1", text: "merge everything")
        feed.start()
        feed.delta("Merging.")
        feed.absorbed(["a2"], text: "also weather?")
        let mark = ErrandMark(submissionID: "s1", text: "merge everything", userItemsBefore: 0)
        #expect(feed.transcript.errandOutcome(for: mark) == nil)
    }
}

@Suite("Absorbed owner echoes still in the outbox")
struct AbsorbedEchoLedgerTests {
    private func absorbedItem(_ admission: String, _ text: String) -> TranscriptItem {
        TranscriptItem(id: "absorbed:\(admission)", content: .user(text: text, delivery: .sent))
    }

    @Test func aPendingEntryWhoseTextWasAbsorbedIsHiddenSoTheBubbleShowsOnce() {
        var ledger = AbsorbedEchoLedger()
        let hidden = ledger.hiddenSubmissions(
            pending: [.init(submissionID: "s1", text: "also this")],
            absorbed: [absorbedItem("a1", "also this")]
        )
        #expect(hidden == ["s1"])
    }

    @Test func anEntryStaysHiddenOnLaterPassesAndTheSameTextSentAgainIsNot() {
        var ledger = AbsorbedEchoLedger()
        let absorbed = [absorbedItem("a1", "ok")]
        _ = ledger.hiddenSubmissions(pending: [.init(submissionID: "s1", text: "ok")], absorbed: absorbed)
        #expect(ledger.hiddenSubmissions(pending: [.init(submissionID: "s1", text: "ok")], absorbed: absorbed) == ["s1"])
        #expect(ledger.hiddenSubmissions(pending: [.init(submissionID: "s2", text: "ok")], absorbed: absorbed).isEmpty)
    }

    @Test func twoPendingEntriesWithOneTextClaimOneAbsorbedBubbleEach() {
        var ledger = AbsorbedEchoLedger()
        let pending: [AbsorbedEchoLedger.Pending] = [.init(submissionID: "s1", text: "ok"), .init(submissionID: "s2", text: "ok")]
        let first = ledger.hiddenSubmissions(pending: pending, absorbed: [absorbedItem("a1", "ok")])
        #expect(first == ["s1"])
        let second = ledger.hiddenSubmissions(pending: pending, absorbed: [absorbedItem("a1", "ok"), absorbedItem("a2", "ok")])
        #expect(second == ["s1", "s2"])
    }

    @Test func textThatWasNeverAbsorbedStaysVisible() {
        var ledger = AbsorbedEchoLedger()
        let hidden = ledger.hiddenSubmissions(
            pending: [.init(submissionID: "s1", text: "mine")],
            absorbed: [absorbedItem("a1", "someone else")]
        )
        #expect(hidden.isEmpty)
    }
}

@Suite("input.absorbed wire event")
struct InputAbsorbedWireTests {
    @Test func decodesTheContractFields() throws {
        let event = SessionEvent(type: "input.absorbed", payload: [
            "turn_id": "t1", "admission_ids": ["a1", "a2"], "message_uid": "m1", "text": "one\n\ntwo",
        ])
        guard case .inputAbsorbed(let absorbed) = event else {
            Issue.record("decoded as \(event)")
            return
        }
        #expect(absorbed.turnID == "t1")
        #expect(absorbed.admissionIDs == ["a1", "a2"])
        #expect(absorbed.messageUID == "m1")
        #expect(absorbed.text == "one\n\ntwo")
    }

    @Test func aFrameWithNothingToPlaceStaysUnknown() {
        let event = SessionEvent(type: "input.absorbed", payload: ["turn_id": "t1"])
        guard case .unknown = event else {
            Issue.record("decoded as \(event)")
            return
        }
    }

    @Test func theSequenceAndEpochEnvelopeGateItLikeMessageFrames() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try Feed.snapshot([("user", "go")], running: true, lastSequence: 0))
        let payload: JSONValue = ["turn_id": "t1", "admission_ids": ["a1"], "text": "hurry"]
        let bare = SessionEventFrame(event: SessionEvent(type: "input.absorbed", payload: payload), sessionID: "s1")
        #expect(transcript.apply(bare) == .ignored)
        let enveloped = SessionEventFrame(
            event: SessionEvent(type: "input.absorbed", payload: payload), sessionID: "s1", seq: 1, replayEpoch: "e1"
        )
        #expect(transcript.apply(enveloped) == .applied)
        #expect(transcript.conversation == ["user: go", "user: hurry"])
    }
}

private struct StatusSubmitter: OutboxSubmitter {
    let status: String

    func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        try JSONValue.object(["admission_id": "a1", "status": .string(status)]).decoded(as: AdmissionStatus.self)
    }
}

@Suite("Submit status")
struct SubmitStatusTests {
    @Test(arguments: ["turn", "steered", "queued"])
    func everyAcceptedSubmitStatusMarksTheEntryDelivered(status: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-absorb-\(UUID().uuidString)")
        let outbox = try Outbox(directory: directory, submitter: StatusSubmitter(status: status))
        let entry = try await outbox.enqueue(botID: "b", text: "hello")
        let result = await outbox.deliver(entry.submissionID)
        guard case .admitted(let admission) = result else {
            Issue.record("expected admitted, got \(result)")
            return
        }
        #expect(admission.status.rawValue == status)
        #expect(await outbox.pending().isEmpty)
    }
}
