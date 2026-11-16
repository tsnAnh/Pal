import Foundation
@testable import PalChat
import PalProtocol
import Testing

private struct Rig {
    var timeline = Timeline()
    private var seq = 0

    init() throws {
        let object: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
        timeline.adoptLive(try object.decoded(as: SessionSnapshot.self))
    }

    @discardableResult
    mutating func send(_ type: String, _ payload: JSONValue) -> ApplyOutcome {
        seq += 1
        return timeline.apply(frame(type, payload, seq: seq))
    }

    func frame(_ type: String, _ payload: JSONValue, seq: Int) -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: "e1")
    }

    mutating func refresh(_ entries: [TimelineEntryWire]) {
        timeline.mergeNewest(TimelinePageWire(entries: entries, older: nil, revision: "r\(entries.count)"))
    }

    var rows: [ChatTimelineRow] { timeline.rows(links: []) }

    var texts: [String] {
        rows.map { row in
            switch row.item.content {
            case .user(let text, _): "user:\(text)"
            case .assistant(let text, _, _): "assistant:\(text)"
            case .clarifyAnswered(let record): "clarify:\(record.question)"
            default: "other"
            }
        }
    }
}

private let answers = """
{"responses": [
{"question": "Q1?", "choices_offered": ["a"], "status": "answered", "user_response": "a"},
{"question": "Q2?", "choices_offered": ["a"], "status": "answered", "user_response": "a"},
{"question": "Q3?", "choices_offered": ["a"], "status": "answered", "user_response": "a"},
{"question": "Q4?", "choices_offered": ["a"], "status": "answered", "user_response": "a"}], "outcome": "submitted"}
"""

private let questions = ["clarify:Q1?", "clarify:Q2?", "clarify:Q3?", "clarify:Q4?"]

private func clarifyEntry(id: String, lead: String) -> TimelineEntryWire {
    TimelineEntryWire(id: id, role: .assistant, text: lead, tools: [TimelineToolWire(callID: "c1", name: "clarify", result: .string(answers))])
}

private func user(_ id: String, _ text: String) -> TimelineEntryWire { TimelineEntryWire(id: id, role: .user, text: text) }

private func assistant(_ id: String, _ text: String) -> TimelineEntryWire { TimelineEntryWire(id: id, role: .assistant, text: text) }

private func ask(_ rig: inout Rig, turn: String, lead: String, streamed: String? = nil, finalUID: String, finalText: String) {
    rig.send("message.start", ["turn_id": .string(turn)])
    rig.send("message.delta", ["text": .string(streamed ?? lead), "turn_id": .string(turn), "segment": 0, "offset": 0])
    rig.send("tool.start", ["tool_id": "c1", "name": "clarify"])
    rig.send("tool.complete", ["tool_id": "c1", "name": "clarify", "result": .string(answers)])
    rig.send("message.delta", ["text": .string(finalText), "turn_id": .string(turn), "segment": 0, "offset": .int(lead.utf16.count)])
    rig.send("message.complete", ["text": .string(finalText), "turn_id": .string(turn), "message_uid": .string(finalUID)])
}

@Suite("Chat transcript identity and order")
struct TimelineIdentityTests {
    @Test func leadInBeforeAnsweredClarifyStaysInPlaceAcrossLaterTurns() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        ask(&rig, turn: "t1", lead: "Quick lead-in", finalUID: "a2", finalText: "Thanks")
        var stored = [user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in"), assistant("a2", "Thanks")]
        rig.refresh(stored)
        var expected = ["user:start", "assistant:Quick lead-in"] + questions + ["assistant:Thanks"]
        #expect(rig.texts == expected)

        for turn in 1...3 {
            rig.timeline.echoUser(submissionID: "s\(turn)", text: "next \(turn)")
            rig.send("message.start", ["turn_id": .string("n\(turn)")])
            rig.send("message.delta", ["text": .string("reply \(turn)"), "turn_id": .string("n\(turn)"), "segment": 0, "offset": 0])
            rig.send("message.complete", ["text": .string("reply \(turn)"), "turn_id": .string("n\(turn)"), "message_uid": .string("r\(turn)")])
            stored += [user("q\(turn)", "next \(turn)"), assistant("r\(turn)", "reply \(turn)")]
            expected += ["user:next \(turn)", "assistant:reply \(turn)"]
            #expect(rig.texts == expected)
            rig.refresh(stored)
            #expect(rig.texts == expected)
        }
    }

    @Test func refreshArrivingWhileTheLeadInStillStreamsDoesNotLeaveALiveCopy() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        rig.send("message.start", ["turn_id": "t1"])
        rig.send("message.delta", ["text": "Quick lead-in", "turn_id": "t1", "segment": 0, "offset": 0])
        rig.refresh([user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in")])
        rig.send("tool.start", ["tool_id": "c1", "name": "clarify"])
        rig.send("tool.complete", ["tool_id": "c1", "name": "clarify", "result": .string(answers)])
        rig.send("message.delta", ["text": "Thanks", "turn_id": "t1", "segment": 0, "offset": 13])
        rig.send("message.complete", ["text": "Thanks", "turn_id": "t1", "message_uid": "a2"])
        let expected = ["user:start", "assistant:Quick lead-in"] + questions + ["assistant:Thanks"]
        #expect(rig.texts == expected)
        rig.refresh([user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in"), assistant("a2", "Thanks")])
        #expect(rig.texts == expected)
    }

    @Test func interimSealOfAnAlreadyStreamedLeadInAddsNoSecondCopy() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        rig.send("message.start", ["turn_id": "t1"])
        rig.send("message.delta", ["text": "Quick lead-in\n\n", "turn_id": "t1", "segment": 0, "offset": 0])
        rig.send("message.interim", ["text": "Quick lead-in", "turn_id": "t1", "segment": 0, "already_streamed": true])
        rig.send("tool.start", ["tool_id": "c1", "name": "clarify"])
        rig.send("tool.complete", ["tool_id": "c1", "name": "clarify", "result": .string(answers)])
        rig.send("message.complete", ["text": "Thanks", "turn_id": "t1", "message_uid": "a2"])
        rig.refresh([user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in"), assistant("a2", "Thanks")])
        #expect(rig.texts == ["user:start", "assistant:Quick lead-in"] + questions + ["assistant:Thanks"])
    }

    @Test func streamedLeadInWithTrailingWhitespaceSettlesOnce() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        ask(&rig, turn: "t1", lead: "Quick lead-in\n\n", finalUID: "a2", finalText: "Thanks")
        rig.refresh([user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in"), assistant("a2", "Thanks")])
        #expect(rig.texts == ["user:start", "assistant:Quick lead-in"] + questions + ["assistant:Thanks"])
    }

    @Test func separateTurnsWithTheSameLeadInStayTwoMessages() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        ask(&rig, turn: "t1", lead: "Quick lead-in", finalUID: "a2", finalText: "Thanks")
        rig.refresh([user("u0", "start"), clarifyEntry(id: "a1", lead: "Quick lead-in"), assistant("a2", "Thanks")])
        rig.timeline.echoUser(submissionID: "s2", text: "again")
        rig.send("message.start", ["turn_id": "t2"])
        rig.send("message.delta", ["text": "Quick lead-in", "turn_id": "t2", "segment": 0, "offset": 0])
        rig.send("tool.start", ["tool_id": "c2", "name": "terminal"])
        rig.send("message.complete", ["text": "Done", "turn_id": "t2", "message_uid": "a4"])
        let texts = rig.texts
        #expect(texts.filter { $0 == "assistant:Quick lead-in" }.count == 2)
        #expect(texts.last == "assistant:Done")
    }

    @Test func replayedFramesChangeNothing() throws {
        var rig = try Rig()
        rig.refresh([user("u0", "start")])
        rig.send("message.start", ["turn_id": "t1"])
        rig.send("message.delta", ["text": "Quick lead-in", "turn_id": "t1", "segment": 0, "offset": 0])
        let before = rig.texts
        let replay = rig.frame("message.delta", ["text": "Quick lead-in", "turn_id": "t1", "segment": 0, "offset": 0], seq: 2)
        #expect(rig.timeline.apply(replay) == .duplicate)
        #expect(rig.texts == before)
    }

    private static let caption = "A short caption"
    private static let stored = "A short caption\n@image:/synthetic/photo.png"

    private func send(_ rig: inout Rig, submission: String, uid: String, carriesImage: Bool) {
        rig.timeline.echoUser(submissionID: submission, text: Self.caption, carriesImage: carriesImage)
        rig.send("message.start", ["turn_id": .string("turn-\(submission)")])
        rig.send("message.complete", ["text": "ok", "turn_id": .string("turn-\(submission)"), "message_uid": .string("r-\(uid)")])
    }

    private func ownerRows(_ rig: Rig) -> [String] {
        rig.rows.compactMap { row in
            if case .user(let text, _) = row.item.content { text } else { nil }
        }
    }

    @Test func captionWithImageIsOneOwnerBubbleThroughRefreshAndReopen() throws {
        var rig = try Rig()
        rig.refresh([])
        send(&rig, submission: "one", uid: "u1", carriesImage: true)
        #expect(ownerRows(rig) == [Self.caption])
        let page = [user("u1", Self.stored), assistant("r-u1", "ok")]
        rig.refresh(page)
        #expect(ownerRows(rig) == [Self.stored])
        rig.refresh(page)
        #expect(ownerRows(rig) == [Self.stored])
        let content = MessageImages.extract(from: Self.stored, role: .user)
        #expect(content.text == Self.caption && content.images.count == 1)

        let cache = try #require(rig.timeline.cacheable(sessionID: "s1"))
        var reopened = Timeline()
        reopened.seed(cache)
        #expect(reopened.rows(links: []).compactMap { row -> String? in
            if case .user(let text, _) = row.item.content { text } else { nil }
        } == [Self.stored])
    }

    @Test func textAloneAndTheSameTextWithAnImageAreDifferentMessages() throws {
        var rig = try Rig()
        rig.refresh([])
        send(&rig, submission: "plain", uid: "u1", carriesImage: false)
        rig.refresh([user("u9", Self.stored), assistant("r-u9", "ok")])
        #expect(ownerRows(rig) == [Self.stored, Self.caption])

        var withImage = try Rig()
        withImage.refresh([])
        send(&withImage, submission: "image", uid: "u1", carriesImage: true)
        withImage.refresh([user("u9", Self.caption), assistant("r-u9", "ok")])
        #expect(ownerRows(withImage) == [Self.caption, Self.caption])
    }

    @Test func twoIdenticalImageSubmissionsStayTwoBubbles() throws {
        var rig = try Rig()
        rig.refresh([])
        send(&rig, submission: "one", uid: "u1", carriesImage: true)
        send(&rig, submission: "two", uid: "u2", carriesImage: true)
        rig.refresh([
            user("u1", Self.stored), assistant("r-u1", "ok"),
            user("u2", Self.stored), assistant("r-u2", "ok"),
        ])
        #expect(ownerRows(rig) == [Self.stored, Self.stored])
    }
}
