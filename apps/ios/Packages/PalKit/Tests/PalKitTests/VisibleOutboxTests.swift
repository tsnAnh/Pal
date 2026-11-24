import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Testing

private struct AdmittingSubmitter: OutboxSubmitter {
    func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        try JSONValue.object(["admission_id": .string("a-\(entry.submissionID)"), "status": "queued"]).decoded(as: AdmissionStatus.self)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-visible-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func entry(_ id: String, _ text: String, at created: Date, _ state: OutboxEntry.State) -> OutboxEntry {
    OutboxEntry(submissionID: id, botID: "b", text: text, attachments: [], createdAt: created, state: state, attempts: 1)
}

private func echo(_ id: String, _ text: String, at date: Date?, delivery: TranscriptItem.Delivery = .sent) -> TranscriptItem {
    TranscriptItem(id: id, content: .user(text: text, delivery: delivery), timestamp: date)
}

private func rows(for entries: [OutboxEntry], in ledger: inout AdmittedEchoLedger, timeline: [TranscriptItem]) -> AdmittedEchoLedger.Resolution {
    ledger.resolve(entries: entries, text: \.text, timeline: timeline)
}

@Suite("An admitted message stays visible until its echo is in the transcript")
struct VisibleOutboxTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func admitted(_ id: String, _ text: String, after seconds: TimeInterval = 0) -> OutboxEntry {
        entry(id, text, at: t0.addingTimeInterval(seconds), .admitted(admissionID: "a-\(id)"))
    }

    @Test func aResyncThatDropsTheLocalEchoLeavesTheAdmittedEntryToRenderTheRow() throws {
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [["role": "user", "text": "go", "row_id": 1]], "running": true,
            "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        transcript.echoUser(submissionID: "s1", text: "while you work")
        #expect(transcript.items.contains { $0.id == "submission:s1" })
        let later: JSONValue = [
            "session_id": "s1", "messages": [["role": "user", "text": "go", "row_id": 1]], "running": true,
            "replay_epoch": "e1", "last_sequence": 4, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        _ = transcript.reconcile(with: try later.decoded(as: SessionSnapshot.self))
        #expect(!transcript.items.contains { $0.id == "submission:s1" })
        var ledger = AdmittedEchoLedger()
        let result = rows(for: [admitted("s1", "while you work")], in: &ledger, timeline: transcript.items)
        #expect(result.unechoed.map(\.submissionID) == ["s1"])
        #expect(AdmittedEchoLedger.rowID(of: result.unechoed[0]) == "submission:s1")
    }

    @Test func fiveMessagesSentDuringATurnShowAtOnceInSendOrderThenEachEchoReplacesItsRow() async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: AdmittingSubmitter())
        var ids: [String] = []
        for number in 1...5 {
            let queued = try await outbox.enqueue(botID: "b", text: "m\(number)")
            #expect(await outbox.deliver(queued.submissionID) != .unknownEntry)
            ids.append(queued.submissionID)
        }
        var ledger = AdmittedEchoLedger()
        let entries = await outbox.snapshot(botID: "b")
        let before = rows(for: entries, in: &ledger, timeline: [])
        #expect(before.unechoed.map(\.submissionID) == ids)
        #expect(before.unechoed.map(\.text) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(before.echoes.isEmpty)
        let echoes = (1...5).map { echo("row:\($0)", "m\($0)", at: Date()) }
        let after = rows(for: entries, in: &ledger, timeline: echoes)
        #expect(after.unechoed.isEmpty)
        #expect(Set(after.echoes.keys) == Set(ids))
        #expect(Set(after.echoes.values).count == 5)
        try await outbox.discardAdmitted(Set(after.echoes.keys))
        #expect(await outbox.snapshot(botID: "b").isEmpty)
    }

    @Test func entriesLoadedAfterARelaunchStayVisibleUntilTheirEchoesArriveThenClear() async throws {
        let directory = try temporaryDirectory()
        let first = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        for number in 1...3 {
            _ = await first.deliver(try await first.enqueue(botID: "b", text: "r\(number)").submissionID)
        }
        let relaunched = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        let entries = await relaunched.snapshot(botID: "b")
        var ledger = AdmittedEchoLedger()
        #expect(rows(for: entries, in: &ledger, timeline: []).unechoed.count == 3)
        let echoes = (1...3).map { echo("row:\($0)", "r\($0)", at: Date()) }
        let result = rows(for: entries, in: &ledger, timeline: echoes)
        #expect(result.unechoed.isEmpty)
        try await relaunched.discardAdmitted(Set(result.echoes.keys))
        try await relaunched.discardAdmitted(Set(result.echoes.keys))
        #expect(await relaunched.snapshot(botID: "b").isEmpty)
        let afterRestart = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        #expect(await afterRestart.snapshot().isEmpty)
    }

    @Test func discardingAdmittedEntriesNeverRemovesAFailedOrPendingOne() async throws {
        let directory = try temporaryDirectory()
        let store = OutboxStore(directory: directory)
        let failed = entry("f", "lost", at: t0, .failed(reason: "refused"))
        let waiting = entry("p", "waiting", at: t0, .pending)
        try store.save([failed, admitted("a1", "one"), waiting, admitted("a2", "two")])
        let outbox = try Outbox(directory: directory, submitter: AdmittingSubmitter())
        try await outbox.discardAdmitted(["f", "p", "a1", "a2"])
        #expect(await outbox.snapshot().map(\.submissionID) == ["f", "p"])
    }

    @Test func aMessageWithTheLocalEchoStillSendingIsNeitherConfirmedNorDrawnTwice() {
        var ledger = AdmittedEchoLedger()
        let local = echo("submission:s1", "hi", at: nil, delivery: .sending)
        let result = rows(for: [admitted("s1", "hi")], in: &ledger, timeline: [local])
        #expect(result.unechoed.isEmpty)
        #expect(result.echoes.isEmpty)
        let queued = echo("submission:s1", "hi", at: nil, delivery: .queued)
        #expect(rows(for: [admitted("s1", "hi")], in: &ledger, timeline: [queued]).echoes == ["s1": "submission:s1"])
    }

    @Test func twoIdenticalMessagesNeedTwoEchoesAndAnOlderIdenticalOneIsNotTheEcho() {
        var ledger = AdmittedEchoLedger()
        let entries = [admitted("s1", "ok"), admitted("s2", "ok", after: 5)]
        let older = echo("row:1", "ok", at: t0.addingTimeInterval(-3_600))
        let one = echo("row:2", "ok", at: t0.addingTimeInterval(6))
        let first = rows(for: entries, in: &ledger, timeline: [older, one])
        #expect(first.echoes == ["s1": "row:2"])
        #expect(first.unechoed.map(\.submissionID) == ["s2"])
        let two = echo("row:3", "ok", at: t0.addingTimeInterval(8))
        let second = rows(for: entries, in: &ledger, timeline: [older, one, two])
        #expect(second.echoes == ["s1": "row:2", "s2": "row:3"])
        #expect(second.unechoed.isEmpty)
    }

    @Test func aDoubleEchoOfOneMessageNeverHidesASecondDistinctMessage() {
        var ledger = AdmittedEchoLedger()
        let own = echo("submission:s1", "ok", at: nil, delivery: .queued)
        let persisted = echo("row:4", "ok", at: t0.addingTimeInterval(1))
        let result = rows(for: [admitted("s1", "ok"), admitted("s2", "ok", after: 2)], in: &ledger, timeline: [own, persisted])
        #expect(result.echoes == ["s1": "submission:s1", "s2": "row:4"])
    }

    @Test func aSteeredEchoThatMergedSeveralMessagesCoversEachOfThem() {
        var ledger = AdmittedEchoLedger()
        let merged = TranscriptItem(id: "absorbed:a-s1", content: .user(text: "one\n\ntwo", delivery: .sent))
        let result = rows(for: [admitted("s1", "one"), admitted("s2", "two", after: 1)], in: &ledger, timeline: [merged])
        #expect(result.echoes == ["s1": "absorbed:a-s1", "s2": "absorbed:a-s1"])
        #expect(result.unechoed.isEmpty)
    }

    @Test func aDuplicateReceiptNeverSubmitsTwice() async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: AdmittingSubmitter())
        let queued = try await outbox.enqueue(botID: "b", text: "once")
        guard case .admitted = await outbox.deliver(queued.submissionID) else {
            Issue.record("not admitted")
            return
        }
        #expect(await outbox.deliver(queued.submissionID) == .alreadyDone)
        #expect(await outbox.snapshot(botID: "b").count == 1)
    }

    @Test func twoIdenticalAdmissionsEachKeepTheirOwnRowWhenTheLocalEchoIsMissing() throws {
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [["role": "user", "text": "go", "row_id": 1]], "running": true,
            "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        transcript.echoUser(submissionID: "s1", text: "ok")
        let info: JSONValue = ["running": true, "pending": [["admission_id": "a-s2", "status": "started", "input_id": "s2", "text": "ok"]]]
        let frame = SessionEventFrame(
            event: SessionEvent(type: "session.info", payload: info), sessionID: "s1", seq: 1, replayEpoch: "e1", executionGeneration: 1
        )
        _ = transcript.apply(frame)
        let texts = transcript.items.compactMap { item -> String? in
            if case .user(let text, _) = item.content { text } else { nil }
        }
        #expect(texts == ["go", "ok", "ok"])
    }
}
