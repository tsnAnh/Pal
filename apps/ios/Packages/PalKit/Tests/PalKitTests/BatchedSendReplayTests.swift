import Foundation
import PalChat
import PalProtocol
import Testing

private let complaint = "the list still jumps"
private let first = "did you see 👩‍👩‍👧\nthis jump"
private let second = "now it no longer scrolls up at all"
private let joined = first + "\n" + second

private struct Send {
    let submission: String
    let admission: String
    let text: String
}

private let sends = [
    Send(submission: "s-c", admission: "adm-c", text: complaint),
    Send(submission: "s-1", admission: "adm-1", text: first),
    Send(submission: "s-2", admission: "adm-2", text: second),
]

private func partLengths(_ texts: [String]) -> JSONValue {
    .array(texts.map { .int($0.unicodeScalars.count) })
}

private let complaintRow = TimelineEntryWire(
    id: "m-c", role: .user, text: complaint, displayMetadata: ["submission_id": "s-c"], rowID: 1
)

private func steerRow(lengths: JSONValue?, text: String = joined) -> TimelineEntryWire {
    var metadata: [String: JSONValue] = ["admission_ids": ["adm-1", "adm-2"]]
    metadata["part_lengths"] = lengths
    return TimelineEntryWire(
        id: "m-steer", role: .user, text: text, displayKind: "steer", displayMetadata: .object(metadata), rowID: 2
    )
}

private let followUpRow = TimelineEntryWire(
    id: "m-batch", role: .user, text: joined,
    displayMetadata: ["submission_id": "s-1", "admission_ids": ["adm-1", "adm-2"], "part_lengths": partLengths([first, second])],
    rowID: 3
)

private func reply(_ id: String, _ text: String, row: Int) -> TimelineEntryWire {
    TimelineEntryWire(id: id, role: .assistant, text: text, rowID: row)
}

private func listed(_ send: Send, _ status: String, steering: Bool = false) -> JSONValue {
    [
        "admission_id": .string(send.admission), "input_id": .string(send.submission), "status": .string(status),
        "steering": .bool(steering), "text": .string(send.text),
    ]
}

private func outboxEntry(_ send: Send, state: OutboxEntry.State) -> OutboxEntry {
    OutboxEntry(
        submissionID: send.submission, botID: "bot", text: send.text, attachments: [], createdAt: Date(), state: state, attempts: 0
    )
}

private final class Replay {
    let script: TimelineScript
    let gateway: FakeGateway
    let session: ChatSession
    private var sequence = 1

    init(stored: [TimelineEntryWire]) async throws {
        let script = TimelineScript(entries: stored)
        script.override("prompt.submit") { number in
            .result(["admission_id": .string(sends[number - 1].admission), "status": "queued"])
        }
        self.script = script
        gateway = try await FakeGateway.start(script.handle)
        session = ChatSession(profile: "bot", connector: script.connector(gateway.url))
        try await session.start()
    }

    func submit(_ send: Send) async throws {
        _ = try await session.submit(outboxEntry(send, state: .pending), files: [])
    }

    func push(_ type: String, _ payload: JSONValue) {
        sequence += 1
        gateway.push(script.event(type, seq: sequence, payload: payload))
    }

    func pending(_ admissions: [JSONValue]) {
        push("session.info", ["running": true, "pending": .array(admissions)])
    }

    func finishTurn(storing rows: [TimelineEntryWire], reply text: String) async -> TimelineSnapshot {
        script.append(rows)
        push("message.complete", ["text": .string(text), "status": "complete"])
        let settled = await waitForTimeline(session) { snapshot in
            rows.allSatisfy { row in snapshot.rows.contains { $0.entryID == row.id } }
        }
        if let settled { return settled }
        return await session.timelineSnapshot
    }

    func shows(_ texts: [String]) async -> [String] {
        let matched = await waitForTimeline(session, timeout: .seconds(2)) { rowTexts($0) == texts }
        if let matched { return rowTexts(matched) }
        return rowTexts(await session.timelineSnapshot)
    }

    func finish() async {
        await session.close()
        gateway.stop()
    }
}

private func unechoed(_ snapshot: TimelineSnapshot, admitted: [Send]) -> [String] {
    var ledger = AdmittedEchoLedger()
    let resolution = ledger.resolve(
        entries: admitted.map { outboxEntry($0, state: .admitted(admissionID: $0.admission)) },
        text: \.text, timeline: snapshot.rows.map(\.item)
    )
    return resolution.unechoed.map(\.submissionID)
}

@Suite("Owner sends made during a turn render once, in order")
struct BatchedSendReplayTests {
    @Test func twoSendsSteeredIntoOneRowStayTwoBubblesAsSent() async throws {
        let chat = try await Replay(stored: [])
        try await chat.submit(sends[0])
        chat.pending([listed(sends[0], "started")])
        chat.push("message.start", ["turn_id": "t1"])
        try await chat.submit(sends[1])
        try await chat.submit(sends[2])
        chat.pending([listed(sends[0], "started"), listed(sends[1], "queued"), listed(sends[2], "queued")])
        chat.push("input.absorbed", [
            "turn_id": "t1", "admission_ids": ["adm-1", "adm-2"], "message_uid": "m-steer", "text": .string(joined),
        ])
        #expect(await chat.shows([complaint, first, second]) == [complaint, first, second])
        let settled = await chat.finishTurn(
            storing: [complaintRow, steerRow(lengths: partLengths([first, second])), reply("m-r", "reply", row: 4)],
            reply: "reply"
        )
        #expect(rowTexts(settled) == [complaint, first, second, "reply"])
        #expect(unechoed(settled, admitted: sends) == [])
        await chat.finish()
    }

    @Test func aChatReopenedAfterTheSteerShowsNoSecondCopyBelowTheReply() async throws {
        let chat = try await Replay(stored: [complaintRow])
        chat.push("message.delta", ["text": "reply", "turn_id": "t1", "segment": 0, "offset": 0])
        chat.pending([
            listed(sends[0], "started"), listed(sends[1], "started", steering: true),
            listed(sends[2], "started", steering: true),
        ])
        #expect(await chat.shows([complaint, first, second]) == [complaint, first, second])
        let settled = await chat.finishTurn(
            storing: [steerRow(lengths: partLengths([first, second])), reply("m-r", "reply", row: 4)], reply: "reply"
        )
        #expect(rowTexts(settled) == [complaint, first, second, "reply"])
        #expect(unechoed(settled, admitted: sends) == [])
        await chat.finish()
    }

    @Test func aFollowUpTurnThatFoldedTwoSendsShowsEachOnce() async throws {
        let chat = try await Replay(stored: [])
        try await chat.submit(sends[0])
        chat.pending([listed(sends[0], "started")])
        chat.push("message.start", ["turn_id": "t1"])
        try await chat.submit(sends[1])
        try await chat.submit(sends[2])
        chat.pending([listed(sends[0], "started"), listed(sends[1], "queued"), listed(sends[2], "queued")])
        _ = await chat.finishTurn(storing: [complaintRow, reply("m-r1", "first reply", row: 2)], reply: "first reply")
        chat.push("message.start", ["turn_id": "t2"])
        chat.pending([listed(sends[1], "started"), listed(sends[2], "started", steering: true)])
        let settled = await chat.finishTurn(storing: [followUpRow, reply("m-r2", "second reply", row: 4)], reply: "second reply")
        chat.push("message.complete", ["admission_id": "adm-2", "outcome": "steered", "text": ""])
        let expected = [complaint, "first reply", first, second, "second reply"]
        #expect(rowTexts(settled) == expected)
        #expect(await chat.shows(expected) == expected)
        #expect(unechoed(settled, admitted: sends) == [])
        await chat.finish()
    }

    @Test func aReloadShowsTheStoredBatchAsTheOwnerSentIt() async throws {
        let chat = try await Replay(stored: [complaintRow, steerRow(lengths: partLengths([first, second]))])
        let snapshot = await chat.session.timelineSnapshot
        #expect(rowTexts(snapshot) == [complaint, first, second])
        #expect(Set(snapshot.rows.map(\.id)).count == 3)
        #expect(Set(snapshot.rows.map(\.item.id)).count == 3)
        #expect(snapshot.rows.map(\.rowID) == [1, 2, 2])
        #expect(unechoed(snapshot, admitted: sends) == [])
        await chat.finish()
    }

    @Test(arguments: [nil, [3, 4] as JSONValue, [4000, 1] as JSONValue, [-1, 34] as JSONValue])
    func aStoredBatchWithoutUsableBoundariesIsOneBubbleAndStillNoCopy(lengths: JSONValue?) async throws {
        let chat = try await Replay(stored: [complaintRow])
        chat.pending([listed(sends[1], "started", steering: true), listed(sends[2], "started", steering: true)])
        #expect(await chat.shows([complaint, first, second]) == [complaint, first, second])
        let settled = await chat.finishTurn(storing: [steerRow(lengths: lengths), reply("m-r", "reply", row: 4)], reply: "reply")
        #expect(rowTexts(settled) == [complaint, joined, "reply"])
        #expect(unechoed(settled, admitted: sends) == [])
        await chat.finish()
    }
}
