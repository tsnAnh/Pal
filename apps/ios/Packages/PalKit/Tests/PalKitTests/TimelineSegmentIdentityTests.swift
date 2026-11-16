import Foundation
@testable import PalChat
import PalProtocol
import Testing

private struct Painted: Equatable {
    let key: RowKey
    let label: String
}

private struct Chat {
    var timeline = Timeline()
    private var sequence = 0
    private(set) var frames: [[Painted]] = []

    mutating func send(_ type: String, _ payload: JSONValue) {
        sequence += 1
        _ = timeline.apply(SessionEventFrame(
            event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: sequence, replayEpoch: "e1", executionGeneration: 1
        ))
        record()
    }

    mutating func echo(_ text: String, submission: String) {
        timeline.echoUser(submissionID: submission, text: text)
        record()
    }

    mutating func page(_ entries: [TimelineEntryWire]) {
        timeline.mergeNewest(TimelinePageWire(entries: entries, older: nil, revision: "r\(sequence)"))
        record()
    }

    mutating func start(_ turn: String) { send("message.start", ["turn_id": .string(turn)]) }

    mutating func delta(_ text: String, turn: String, segment: Int, offset: Int) {
        send("message.delta", ["text": .string(text), "turn_id": .string(turn), "segment": .int(segment), "offset": .int(offset)])
    }

    mutating func interim(_ text: String, turn: String, segment: Int, streamed: Bool) {
        send("message.interim", ["text": .string(text), "already_streamed": .bool(streamed), "turn_id": .string(turn), "segment": .int(segment)])
    }

    mutating func tool(_ id: String, name: String = "terminal", result: String = "{\"exit_code\": 0}") {
        send("tool.start", ["tool_id": .string(id), "name": .string(name)])
        send("tool.complete", ["tool_id": .string(id), "name": .string(name), "result": .string(result)])
    }

    mutating func complete(_ text: String, rows: [Int], user: String, final: String) {
        send("message.complete", [
            "text": .string(text), "status": "complete",
            "persisted_turn": [
                "row_ids": .array(rows.map(JSONValue.int)), "complete": true,
                "user_message_uid": .string(user), "final_assistant_message_uid": .string(final),
            ],
        ])
    }

    var labels: [String] { frames.last?.map(\.label) ?? [] }

    private mutating func record() {
        frames.append(timeline.rows(links: []).map { Painted(key: $0.id, label: Self.label($0.item)) })
    }

    private static func label(_ item: TranscriptItem) -> String {
        switch item.content {
        case .user(let text, _): "U:" + text
        case .assistant(let text, _, _): "A:" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .clarify: "clarify-card"
        case .clarifyAnswered(let record): "answered:" + record.question
        case .approval, .approvalAnswered: "approval-card"
        case .tool(let call): "tool:" + call.toolID
        case .connection: "connection"
        case .botThread: "thread"
        }
    }
}

private func user(_ uid: String, _ text: String, row: Int) -> TimelineEntryWire {
    TimelineEntryWire(id: uid, role: .user, text: text, rowID: row)
}

private func assistant(_ uid: String, _ text: String, row: Int, tools: [TimelineToolWire] = []) -> TimelineEntryWire {
    TimelineEntryWire(id: uid, role: .assistant, text: text, rowID: row, tools: tools)
}

private func expectSteady(_ chat: Chat, removable: Set<String> = ["clarify-card"], sourceLocation: SourceLocation = #_sourceLocation) {
    for (index, frame) in chat.frames.enumerated() {
        let labels = frame.map(\.label)
        let repeated = Set(labels.filter { label in labels.count { $0 == label } > 1 })
        #expect(repeated.isEmpty, "frame \(index) paints \(repeated.sorted()) more than once: \(labels)", sourceLocation: sourceLocation)
    }
    for (index, pair) in zip(chat.frames, chat.frames.dropFirst()).enumerated() {
        let (before, after) = pair
        let afterKeys = after.map(\.key)
        for painted in before where !afterKeys.contains(painted.key) && !removable.contains(painted.label) {
            Issue.record("\(painted.label) lost its row identity \(painted.key) at frame \(index + 1): \(after.map(\.label))", sourceLocation: sourceLocation)
        }
        let kept = before.map(\.key).filter(afterKeys.contains)
        let keptAfter = afterKeys.filter(kept.contains)
        #expect(kept == keptAfter, "painted rows reordered at frame \(index + 1): \(before.map(\.label)) -> \(after.map(\.label))", sourceLocation: sourceLocation)
    }
}

@Suite("Timeline segment identity")
struct TimelineSegmentIdentityTests {
    static let commentary = "Pal đã nhận việc 145 nhưng cần xem hàng đợi trước."
    static let final = "Em đã gửi PixelPop cho anh."

    @Test func streamedCommentarySealedByAnInterimPaintsOncePerStoredRow() {
        var chat = Chat()
        chat.echo("ship it", submission: "s-1")
        chat.start("t1")
        chat.tool("call-a")
        chat.delta(Self.commentary + "\n\n", turn: "t1", segment: 0, offset: 0)
        chat.interim(Self.commentary, turn: "t1", segment: 0, streamed: true)
        chat.tool("call-b")
        chat.delta(Self.final, turn: "t1", segment: 1, offset: 0)
        chat.complete(Self.final, rows: [5526, 5527, 5528, 5529, 5530, 5531], user: "u5526", final: "u5531")
        chat.page([
            user("u5526", "ship it", row: 5526),
            assistant("u5529", Self.commentary + "\n\n", row: 5529),
            assistant("u5531", Self.final, row: 5531),
        ])
        #expect(chat.labels == ["U:ship it", "A:" + Self.commentary, "A:" + Self.final])
        expectSteady(chat)
    }

    @Test func commentaryDeliveredOnlyAsAnInterimBindsToItsStoredRowWhateverItsText() {
        var chat = Chat()
        chat.echo("rotate the key", submission: "s-1")
        chat.start("t1")
        chat.interim("Rotating key sk-***.", turn: "t1", segment: 0, streamed: false)
        chat.tool("call-a")
        chat.delta(Self.final, turn: "t1", segment: 1, offset: 0)
        chat.complete(Self.final, rows: [10, 11, 12, 13], user: "u10", final: "u13")
        chat.page([
            user("u10", "rotate the key", row: 10),
            assistant("u11", "Rotating key sk-abc123.", row: 11),
            assistant("u13", Self.final, row: 13),
        ])
        #expect(chat.labels == ["U:rotate the key", "A:Rotating key sk-abc123.", "A:" + Self.final])
        expectSteady(chat)
    }

    @Test func commentaryStreamedWithoutAnInterimPaintsOncePerStoredRow() {
        var chat = Chat()
        chat.echo("go", submission: "s-1")
        chat.start("t1")
        chat.delta(Self.commentary + "\n", turn: "t1", segment: 0, offset: 0)
        chat.tool("call-a")
        chat.delta(Self.final, turn: "t1", segment: 0, offset: 40)
        chat.complete(Self.final, rows: [1, 2, 3, 4], user: "u1", final: "u4")
        chat.page([user("u1", "go", row: 1), assistant("u2", Self.commentary, row: 2), assistant("u4", Self.final, row: 4)])
        #expect(chat.labels == ["U:go", "A:" + Self.commentary, "A:" + Self.final])
        expectSteady(chat)
    }

    @Test func aPageLandingMidTurnNeverLeavesALiveCopyBelowTheReply() {
        var chat = Chat()
        chat.echo("go", submission: "s-1")
        chat.start("t1")
        chat.delta(Self.commentary + " ", turn: "t1", segment: 0, offset: 0)
        chat.interim(Self.commentary, turn: "t1", segment: 0, streamed: true)
        chat.send("tool.start", ["tool_id": "call-a", "name": "terminal"])
        chat.page([user("u1", "go", row: 1), assistant("u2", Self.commentary + " ", row: 2)])
        chat.send("tool.complete", ["tool_id": "call-a", "name": "terminal", "result": "{}"])
        chat.delta(Self.final, turn: "t1", segment: 1, offset: 0)
        chat.complete(Self.final, rows: [1, 2, 3, 4], user: "u1", final: "u4")
        chat.page([user("u1", "go", row: 1), assistant("u2", Self.commentary + " ", row: 2), assistant("u4", Self.final, row: 4)])
        #expect(chat.labels == ["U:go", "A:" + Self.commentary, "A:" + Self.final])
        expectSteady(chat)
    }

    @Test func aMidTurnPageWithDifferentStoredTextSettlesToOneCopyOnceTheTurnCompletes() {
        var chat = Chat()
        chat.echo("go", submission: "s-1")
        chat.start("t1")
        chat.interim("Checking sk-***.", turn: "t1", segment: 0, streamed: false)
        chat.send("tool.start", ["tool_id": "call-a", "name": "terminal"])
        chat.page([user("u1", "go", row: 1), assistant("u2", "Checking sk-abc.", row: 2)])
        chat.send("tool.complete", ["tool_id": "call-a", "name": "terminal", "result": "{}"])
        chat.delta(Self.final, turn: "t1", segment: 1, offset: 0)
        chat.complete(Self.final, rows: [1, 2, 3, 4], user: "u1", final: "u4")
        let settledKey = chat.frames.last?.first { $0.label == "A:Checking sk-abc." }?.key
        chat.page([user("u1", "go", row: 1), assistant("u2", "Checking sk-abc.", row: 2), assistant("u4", Self.final, row: 4)])
        #expect(chat.labels == ["U:go", "A:Checking sk-abc.", "A:" + Self.final])
        #expect(chat.frames.last?.first { $0.label == "A:Checking sk-abc." }?.key == settledKey)
    }

    @Test func aClarifyTurnKeepsCommentaryQuestionAndReplyInPlace() {
        var chat = Chat()
        chat.echo("pick one", submission: "s-1")
        chat.start("t1")
        chat.delta(Self.commentary + "\n", turn: "t1", segment: 0, offset: 0)
        chat.interim(Self.commentary, turn: "t1", segment: 0, streamed: true)
        chat.send("tool.start", ["tool_id": "call-q", "name": "clarify"])
        chat.send("clarify.request", [
            "kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which?", "choices": ["a", "b"],
        ])
        chat.send("clarify.settled", ["prompt_id": "p1"])
        let answer = "{\"responses\": [{\"question\": \"Which?\", \"status\": \"answered\", \"user_response\": [\"b\"]}]}"
        chat.send("tool.complete", ["tool_id": "call-q", "name": "clarify", "result": .string(answer)])
        chat.delta("Got it, b.", turn: "t1", segment: 1, offset: 0)
        chat.complete("Got it, b.", rows: [1, 2, 3, 4], user: "u1", final: "u4")
        chat.page([
            user("u1", "pick one", row: 1),
            assistant("u2", Self.commentary + "\n", row: 2, tools: [TimelineToolWire(callID: "call-q", name: "clarify", result: .string(answer))]),
            assistant("u4", "Got it, b.", row: 4),
        ])
        #expect(chat.labels == ["U:pick one", "A:" + Self.commentary, "answered:Which?", "A:Got it, b."])
        expectSteady(chat)
    }

    @Test func anAnsweredApprovalCardStaysAboveTheReplyOnceTheTurnSettles() {
        var chat = Chat()
        chat.echo("clean up", submission: "s-1")
        chat.start("t1")
        chat.send("tool.start", ["tool_id": "call-x", "name": "terminal"])
        chat.send("approval.request", [
            "kind": "approval", "prompt_id": "p2", "execution_generation": 1, "command": "rm -rf build", "choices": ["once", "deny"],
        ])
        chat.timeline.noteApprovalChoice("deny", promptID: "p2")
        chat.send("approval.settled", ["prompt_id": "p2"])
        chat.send("tool.complete", ["tool_id": "call-x", "name": "terminal", "result": "{\"error\": \"denied\"}"])
        chat.delta("Skipped it.", turn: "t1", segment: 0, offset: 0)
        chat.complete("Skipped it.", rows: [1, 2, 3, 4], user: "u1", final: "u4")
        chat.page([
            user("u1", "clean up", row: 1),
            assistant("u2", "", row: 2, tools: [TimelineToolWire(callID: "call-x", name: "terminal")]),
            assistant("u4", "Skipped it.", row: 4),
        ])
        #expect(chat.labels == ["U:clean up", "approval-card", "A:Skipped it."])
        expectSteady(chat)
    }

    @Test func aMachineNoticeArrivingMidTurnSettlesInPlace() {
        let notice = "[IMPORTANT: Background process proc_1 exited with code 0]"
        var chat = Chat()
        chat.echo("build it", submission: "s-1")
        chat.start("t1")
        chat.delta(Self.commentary, turn: "t1", segment: 0, offset: 0)
        chat.interim(Self.commentary, turn: "t1", segment: 0, streamed: true)
        chat.tool("call-a")
        chat.send("input.absorbed", ["turn_id": "t1", "message_uid": "u3", "text": .string(notice), "display_kind": "process_complete"])
        chat.delta(Self.final, turn: "t1", segment: 2, offset: 0)
        chat.complete(Self.final, rows: [1, 2, 3, 4, 5], user: "u1", final: "u5")
        chat.page([
            user("u1", "build it", row: 1),
            assistant("u2", Self.commentary, row: 2),
            TimelineEntryWire(id: "u3", role: .notice, text: notice, displayKind: "process_complete", rowID: 3),
            assistant("u5", Self.final, row: 5),
        ])
        #expect(chat.labels == ["U:build it", "A:" + Self.commentary, "U:" + notice, "A:" + Self.final])
        expectSteady(chat)
    }

    @Test func twoIdenticalRepliesBothStay() {
        var chat = Chat()
        chat.echo("ping", submission: "s-1")
        chat.start("t1")
        chat.delta("On it.", turn: "t1", segment: 0, offset: 0)
        chat.interim("On it.", turn: "t1", segment: 0, streamed: true)
        chat.tool("call-a")
        chat.delta("On it.", turn: "t1", segment: 1, offset: 0)
        chat.complete("On it.", rows: [1, 2, 3, 4], user: "u1", final: "u4")
        let turnOne = [user("u1", "ping", row: 1), assistant("u2", "On it.", row: 2), assistant("u4", "On it.", row: 4)]
        chat.page(turnOne)
        chat.echo("ping again", submission: "s-2")
        chat.start("t2")
        chat.delta("On it.", turn: "t2", segment: 0, offset: 0)
        chat.complete("On it.", rows: [5, 6], user: "u5", final: "u6")
        chat.page(turnOne + [user("u5", "ping again", row: 5), assistant("u6", "On it.", row: 6)])
        #expect(chat.labels == ["U:ping", "A:On it.", "A:On it.", "U:ping again", "A:On it."])
        #expect(Set(chat.frames.last?.map(\.key) ?? []).count == 5)
    }
}
