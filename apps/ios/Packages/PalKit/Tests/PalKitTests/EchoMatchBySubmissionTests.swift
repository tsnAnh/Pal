import Foundation
@testable import PalChat
import PalProtocol
import Testing

private struct AdmittingSubmitter: OutboxSubmitter {
    func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        try JSONValue.object(["admission_id": .string("a-\(entry.submissionID)"), "status": "queued"]).decoded(as: AdmissionStatus.self)
    }
}

private let caption = "A short caption"
private let imageLine = "@image:/synthetic/photo.png"
private let stored = "\(caption)\n\(imageLine)"
private let photo = PromptAttachment(path: "/synthetic/photo.png", mime: "image/png")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func storedUser(_ id: String, _ text: String, submission: String?) -> TimelineEntryWire {
    TimelineEntryWire(
        id: id, role: .user, text: text,
        displayMetadata: submission.map { JSONValue.object(["submission_id": .string($0)]) }
    )
}

private func reply(_ id: String, _ text: String) -> TimelineEntryWire { TimelineEntryWire(id: id, role: .assistant, text: text) }

private struct Rig {
    var timeline = Timeline()
    private var seq = 0

    init() throws {
        let object: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
        timeline.adoptLive(try object.decoded(as: SessionSnapshot.self))
    }

    mutating func send(_ type: String, _ payload: JSONValue) {
        seq += 1
        _ = timeline.apply(SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: "e1"))
    }

    mutating func refresh(_ entries: [TimelineEntryWire]) {
        timeline.mergeNewest(TimelinePageWire(entries: entries, older: nil, revision: "r\(entries.count)"))
    }

    var owner: [(text: String, delivery: TranscriptItem.Delivery)] {
        timeline.rows(links: []).compactMap { row in
            if case .user(let text, let delivery) = row.item.content { (text, delivery) } else { nil }
        }
    }
}

@Suite("A sent message with an image is matched to its stored row by submission id")
struct EchoMatchBySubmissionTests {
    @Test(arguments: [stored, imageLine, "Merged caption, nothing like the typed one\n\(imageLine)"])
    func theStoredRowReplacesTheLocalEchoWhateverItsTextReadsInEitherOrder(storedText: String) throws {
        var streamFirst = try Rig()
        streamFirst.refresh([])
        streamFirst.timeline.echoUser(submissionID: "s1", text: caption, carriesImage: true)
        streamFirst.send("message.start", ["turn_id": "t1"])
        streamFirst.refresh([storedUser("u1", storedText, submission: "s1")])
        #expect(streamFirst.owner.map(\.text) == [storedText])
        #expect(streamFirst.owner.map(\.delivery) == [.sent])

        var storedFirst = try Rig()
        storedFirst.refresh([])
        storedFirst.timeline.echoUser(submissionID: "s1", text: caption, carriesImage: true)
        storedFirst.refresh([storedUser("u1", storedText, submission: "s1")])
        storedFirst.send("message.start", ["turn_id": "t1"])
        storedFirst.refresh([storedUser("u1", storedText, submission: "s1"), reply("a1", "ok")])
        #expect(storedFirst.owner.map(\.text) == [storedText])
        #expect(storedFirst.owner.map(\.delivery) == [.sent])
    }

    @Test func aMessageWithOnlyAnImageIsOneRow() throws {
        var rig = try Rig()
        rig.refresh([])
        rig.timeline.echoUser(submissionID: "s1", text: "", carriesImage: true)
        rig.refresh([storedUser("u1", imageLine, submission: "s1")])
        #expect(rig.owner.map(\.text) == [imageLine])
        #expect(rig.owner.map(\.delivery) == [.sent])
    }

    @Test func twoIdenticalImageMessagesSentInARowStayTwoRows() throws {
        var rig = try Rig()
        rig.refresh([])
        rig.timeline.echoUser(submissionID: "one", text: caption, carriesImage: true)
        rig.timeline.echoUser(submissionID: "two", text: caption, carriesImage: true)
        rig.refresh([storedUser("u1", stored, submission: "one")])
        #expect(rig.owner.map(\.text) == [stored, caption])
        #expect(rig.owner.map(\.delivery) == [.sent, .sending])
        rig.refresh([storedUser("u1", stored, submission: "one"), storedUser("u2", stored, submission: "two")])
        #expect(rig.owner.map(\.text) == [stored, stored])
        #expect(rig.owner.map(\.delivery) == [.sent, .sent])
    }

    @Test func aStoredRowOfAnEarlierSubmissionIsNeverTakenForALaterIdenticalEcho() throws {
        var rig = try Rig()
        rig.refresh([storedUser("u1", stored, submission: "old")])
        rig.timeline.echoUser(submissionID: "new", text: caption, carriesImage: true)
        rig.refresh([storedUser("u1", stored, submission: "old")])
        #expect(rig.owner.map(\.text) == [stored, caption])
        #expect(rig.owner.map(\.delivery) == [.sent, .sending])
    }

    @Test func aStoredRowWithoutAnIdStillSettlesTheEchoByText() throws {
        var rig = try Rig()
        rig.refresh([])
        rig.timeline.echoUser(submissionID: "s1", text: caption, carriesImage: true)
        rig.send("message.start", ["turn_id": "t1"])
        rig.refresh([storedUser("u1", stored, submission: nil)])
        #expect(rig.owner.map(\.text) == [stored])
    }
}

@Suite("An admitted outbox entry clears once any stored row carries its submission id")
struct AdmittedEntryClearsBySubmissionTests {
    private func entry(_ id: String, text: String, attachments: [PromptAttachment], after seconds: TimeInterval = 0) -> OutboxEntry {
        OutboxEntry(
            submissionID: id, botID: "b", text: text, attachments: attachments,
            createdAt: t0.addingTimeInterval(seconds), state: .admitted(admissionID: "a-\(id)"), attempts: 1
        )
    }

    private func row(_ id: String, _ text: String, submission: String?, at seconds: TimeInterval = 1) -> TranscriptItem {
        var item = TranscriptItem(id: id, content: .user(text: text, delivery: .sent), timestamp: t0.addingTimeInterval(seconds))
        item.submissionID = submission
        return item
    }

    private func resolve(_ ledger: inout AdmittedEchoLedger, _ entries: [OutboxEntry], _ timeline: [TranscriptItem]) -> AdmittedEchoLedger.Resolution {
        ledger.resolve(entries: entries, text: { $0.text.isEmpty ? "Photo" : $0.text }, timeline: timeline)
    }

    @Test func aCaptionedImageIsEchoedByIdEvenThoughTheStoredTextCarriesTheReference() {
        var ledger = AdmittedEchoLedger()
        let result = resolve(&ledger, [entry("s1", text: caption, attachments: [photo])], [row("row:1", stored, submission: "s1")])
        #expect(result.echoes == ["s1": "row:1"])
        #expect(result.unechoed.isEmpty)
    }

    @Test func anImageOnlyMessageIsEchoedById() {
        var ledger = AdmittedEchoLedger()
        let result = resolve(&ledger, [entry("s1", text: "", attachments: [photo])], [row("row:1", imageLine, submission: "s1")])
        #expect(result.echoes == ["s1": "row:1"])
        #expect(result.unechoed.isEmpty)
    }

    @Test func aStoredRowOfAnotherSubmissionNeverStandsInForAnIdenticalMessage() {
        var ledger = AdmittedEchoLedger()
        let entries = [entry("one", text: caption, attachments: [photo]), entry("two", text: caption, attachments: [photo], after: 5)]
        let first = resolve(&ledger, entries, [row("row:1", stored, submission: "one", at: 6)])
        #expect(first.echoes == ["one": "row:1"])
        #expect(first.unechoed.map(\.submissionID) == ["two"])
        let second = resolve(&ledger, entries, [row("row:1", stored, submission: "one", at: 6), row("row:2", stored, submission: "two", at: 7)])
        #expect(second.echoes == ["one": "row:1", "two": "row:2"])
        #expect(second.unechoed.isEmpty)
    }

    @Test func aRowWithoutAnIdIsMatchedByTextOnlyWithTheSameImageCount() {
        var ledger = AdmittedEchoLedger()
        let withImage = resolve(&ledger, [entry("s1", text: caption, attachments: [photo])], [row("row:1", stored, submission: nil)])
        #expect(withImage.echoes == ["s1": "row:1"])
        var plain = AdmittedEchoLedger()
        let textOnly = resolve(&plain, [entry("s2", text: caption, attachments: [])], [row("row:1", stored, submission: nil)])
        #expect(textOnly.echoes.isEmpty)
        #expect(textOnly.unechoed.map(\.submissionID) == ["s2"])
    }

    @Test func afterARestartAdmittedEntriesWhoseRowsAreInHistoryClearAndFailedOnesStay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        var ids: [String] = []
        for number in 1...3 {
            let queued = try await first.enqueue(botID: "b", text: number == 2 ? "" : "m\(number)", attachments: [photo])
            _ = await first.deliver(queued.submissionID)
            ids.append(queued.submissionID)
        }
        let waiting = try await first.enqueue(botID: "b", text: "still sending")
        let relaunched = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        let entries = await relaunched.snapshot(botID: "b")
        let history = ids.enumerated().map { index, id in
            row("row:\(index + 1)", index == 1 ? imageLine : "m\(index + 1)\n\(imageLine)", submission: id, at: 0)
        }
        var ledger = AdmittedEchoLedger()
        let result = resolve(&ledger, entries, history)
        #expect(Set(result.echoes.keys) == Set(ids))
        #expect(result.unechoed.isEmpty)
        try await relaunched.discardAdmitted(Set(result.echoes.keys))
        #expect(await relaunched.snapshot(botID: "b").map(\.submissionID) == [waiting.submissionID])
    }
}

@Suite("A queued or absorbed image message is matched to its echo by admission id")
struct AbsorbedImageEchoTests {
    private func makeTranscript(history: [JSONValue]) throws -> Transcript {
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": .array(history), "running": true,
            "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func apply(_ transcript: inout Transcript, _ sequence: Int, _ type: String, _ payload: JSONValue) {
        _ = transcript.apply(SessionEventFrame(
            event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: sequence, replayEpoch: "e1", executionGeneration: 1
        ))
    }

    private func users(_ transcript: Transcript) -> [(text: String, delivery: TranscriptItem.Delivery)] {
        transcript.items.compactMap { item in
            if case .user(let text, let delivery) = item.content { (text, delivery) } else { nil }
        }
    }

    private func queued(text: String) -> JSONValue {
        ["running": true, "pending": [["admission_id": "a-s1", "status": "queued", "input_id": "s1", "text": .string(text)]]]
    }

    private let go: JSONValue = ["role": "user", "text": "go", "row_id": 1]

    @Test func anAbsorbedCaptionWithItsImageReferenceIsTheEchoNotASecondRow() throws {
        var transcript = try makeTranscript(history: [go])
        transcript.echoUser(submissionID: "s1", text: caption, carriesImage: true)
        apply(&transcript, 1, "session.info", queued(text: caption))
        apply(&transcript, 2, "input.absorbed", ["turn_id": "t1", "admission_ids": ["a-s1"], "message_uid": "m-1", "text": .string(stored)])
        #expect(users(transcript).map(\.text) == ["go", caption])
        #expect(users(transcript).map(\.delivery) == [.sent, .sent])
        #expect(transcript.absorbedWithoutEcho.isEmpty)
    }

    @Test func anAbsorbedImageOnlyMessageIsTheEchoNotASecondRow() throws {
        var transcript = try makeTranscript(history: [go])
        transcript.echoUser(submissionID: "s1", text: "", carriesImage: true)
        apply(&transcript, 1, "session.info", queued(text: ""))
        apply(&transcript, 2, "input.absorbed", ["turn_id": "t1", "admission_ids": ["a-s1"], "message_uid": "m-1", "text": .string(imageLine)])
        #expect(users(transcript).map(\.delivery) == [.sent, .sent])
        #expect(users(transcript).count == 2)
        #expect(transcript.absorbedWithoutEcho.isEmpty)
    }

    @Test func aStartedAdmissionWhoseRowIsStoredWithItsIdAddsNoSecondRow() throws {
        let row: JSONValue = ["role": "user", "text": .string(stored), "row_id": 2, "display_metadata": ["submission_id": "s1"]]
        var transcript = try makeTranscript(history: [go, row])
        let info: JSONValue = ["running": true, "pending": [["admission_id": "a-s1", "status": "started", "input_id": "s1", "text": .string(caption)]]]
        apply(&transcript, 1, "session.info", info)
        #expect(users(transcript).map(\.text) == ["go", stored])
    }

    @Test func aSecondAdmissionWithTheSameTextAsAStoredRowOfAnotherSubmissionKeepsItsOwnRow() throws {
        let row: JSONValue = ["role": "user", "text": "ok", "row_id": 2, "display_metadata": ["submission_id": "s1"]]
        var transcript = try makeTranscript(history: [go, row])
        let info: JSONValue = ["running": true, "pending": [["admission_id": "a-s2", "status": "started", "input_id": "s2", "text": "ok"]]]
        apply(&transcript, 1, "session.info", info)
        #expect(users(transcript).map(\.text) == ["go", "ok", "ok"])
    }
}
