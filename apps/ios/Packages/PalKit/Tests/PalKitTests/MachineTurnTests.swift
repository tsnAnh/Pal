import Foundation
import PalChat
import PalProtocol
import Testing

private let delegation = """
[ASYNC DELEGATION BATCH COMPLETE — deleg_7f3a] A background fan-out unit you dispatched earlier — 2 subagent(s) — has finished.
"""
private let processDone = "[IMPORTANT: Background process proc_1 exited with code 2]\nbuild failed"

private struct Machine {
    var transcript = Transcript()
    private var sequence = 0

    init(pending: [JSONValue] = []) throws {
        let object: JSONValue = [
            "session_id": "s1", "messages": [], "running": true, "replay_epoch": "e1", "last_sequence": 0,
            "execution_generation": 1, "pending": .array(pending), "prompts": [],
        ]
        _ = transcript.reconcile(with: try object.decoded(as: SessionSnapshot.self))
    }

    mutating func send(_ type: String, _ payload: JSONValue) {
        sequence += 1
        _ = transcript.apply(SessionEventFrame(
            event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: sequence, replayEpoch: "e1",
            executionGeneration: 1
        ))
    }

    func inbound(of text: String) -> InboundKind? {
        transcript.items.first { item in
            if case .user(let shown, _) = item.content { shown == text } else { false }
        }?.inbound
    }
}

private func admission(_ text: String, kind: String?, status: String = "queued", id: String = "a1") -> JSONValue {
    var object: [String: JSONValue] = [
        "admission_id": .string(id), "status": .string(status), "input_id": .string("in-\(id)"), "text": .string(text),
    ]
    if let kind { object["display_kind"] = .string(kind) }
    return .object(object)
}

@Suite struct MachineTurnTests {
    static let machine: [(text: String, kind: String)] = [
        (delegation, "async_delegation_complete"), (processDone, "process_complete"),
    ]

    @Test(arguments: [0, 1]) func liveQueuedAdmissionOfAMachineTurnIsNeverTheOwnersBubble(_ index: Int) throws {
        let (text, kind) = Self.machine[index]
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission(text, kind: kind)]])
        #expect(chat.inbound(of: text) == .processCompletion)
    }

    @Test(arguments: [0, 1]) func startedAdmissionEchoOfAMachineTurnIsNeverTheOwnersBubble(_ index: Int) throws {
        let (text, kind) = Self.machine[index]
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission(text, kind: kind, status: "started")]])
        #expect(chat.inbound(of: text) == .processCompletion)
    }

    @Test(arguments: [0, 1]) func snapshotPendingMachineTurnIsNeverTheOwnersBubble(_ index: Int) throws {
        let (text, kind) = Self.machine[index]
        let chat = try Machine(pending: [admission(text, kind: kind)])
        #expect(chat.inbound(of: text) == .processCompletion)
    }

    @Test func absorbedMachineRemainderIsNeverTheOwnersBubble() throws {
        var chat = try Machine()
        chat.send("input.absorbed", [
            "turn_id": "t1", "admission_ids": ["a9"], "message_uid": "m1", "text": .string(delegation),
        ])
        #expect(chat.inbound(of: delegation.trimmingCharacters(in: .whitespacesAndNewlines)) == .processCompletion)
    }

    @Test func absorbedOwnerSteerStaysTheOwnersBubble() throws {
        var chat = try Machine()
        chat.send("input.absorbed", [
            "turn_id": "t1", "admission_ids": ["a9"], "message_uid": "m1", "text": "also check totals", "display_kind": "steer",
        ])
        #expect(chat.inbound(of: "also check totals") == .person)
    }

    @Test func oldServerDelegationHeaderWithoutKindIsAProcessCompletion() throws {
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission(delegation, kind: nil)]])
        #expect(chat.inbound(of: delegation) == .processCompletion)
    }

    @Test func internalNotificationAdmissionIsANotice() throws {
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission("[heartbeat] tick", kind: "internal_notification")]])
        #expect(chat.inbound(of: "[heartbeat] tick") == .systemNotification)
    }

    @Test func hiddenAdmissionIsNeverShown() throws {
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission("kickoff", kind: "hidden")]])
        #expect(chat.inbound(of: "kickoff") == nil)
    }

    @Test func ownersQueuedAdmissionStaysTheOwnersBubble() throws {
        var chat = try Machine()
        chat.send("session.info", ["running": true, "pending": [admission("hello there", kind: nil)]])
        #expect(chat.inbound(of: "hello there") == .person)
    }
}
