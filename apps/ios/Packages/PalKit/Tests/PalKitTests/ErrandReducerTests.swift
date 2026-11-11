import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Errand outcome reducer")
struct ErrandReducerTests {
    private struct Rig {
        var transcript = Transcript()
        var sequence = 0

        init(running: Bool = false, rows: [(String, String)] = []) throws {
            let messages: [JSONValue] = rows.enumerated().map {
                ["role": .string($1.0), "text": .string($1.1), "row_id": .int($0 + 1)]
            }
            let snapshot: JSONValue = [
                "session_id": "s1", "messages": .array(messages), "running": .bool(running), "replay_epoch": "e1",
                "last_sequence": 0, "execution_generation": 1, "pending": [], "prompts": [],
            ]
            _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        }

        mutating func push(_ type: String, _ payload: JSONValue = [:]) {
            sequence += 1
            let event = SessionEventFrame(
                event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: sequence, replayEpoch: "e1"
            )
            _ = transcript.apply(event)
        }

        mutating func ask(_ text: String, id: String = "ask") -> ErrandMark {
            let mark = ErrandMark(submissionID: id, text: text, userItemsBefore: transcript.userItemCount)
            transcript.echoUser(submissionID: id, text: text)
            return mark
        }

        mutating func answer(_ text: String, segment: Int = 0) {
            push("message.delta", ["text": .string(text), "segment": .int(segment), "offset": 0])
        }
    }

    private let clarify: JSONValue = [
        "kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?", "choices": ["a", "b"],
    ]

    @Test func notSettledUntilTheTurnThatFollowedOurMessageHasFinished() throws {
        var rig = try Rig()
        let mark = rig.ask("hello")
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "echo only")
        rig.push("message.start")
        rig.answer("hi")
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "still streaming")
        rig.push("message.complete", ["text": "hi there"])
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("hi there"))
    }

    @Test func aTurnThatWasRunningBeforeWeSubmittedNeverAnswersForUs() throws {
        var rig = try Rig()
        rig.push("message.start")
        rig.answer("earlier turn, part one. ")
        let mark = rig.ask("my question")
        rig.answer("earlier turn, part two.", segment: 1)
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "our message is not admitted yet")
        rig.push("message.complete", ["text": "earlier turn, part two."])
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "the earlier turn finishing is not our turn")
        rig.push("message.start")
        rig.answer("my answer")
        rig.push("message.complete", ["text": "my answer"])
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("my answer"))
    }

    @Test func aReplySplitAcrossToolCallsIsJoinedInOrder() throws {
        var rig = try Rig()
        let mark = rig.ask("look it up")
        rig.push("message.start")
        rig.answer("Let me check.")
        rig.push("tool.start", ["tool_id": "t1", "name": "search"])
        rig.push("tool.complete", ["tool_id": "t1", "name": "search", "summary": "done"])
        rig.answer("It is sunny.", segment: 1)
        #expect(rig.transcript.errandOutcome(for: mark) == nil)
        rig.push("message.complete", ["text": "It is sunny."])
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("Let me check.\n\nIt is sunny."))
    }

    @Test(arguments: ["clarify.request", "approval.request"])
    func aPromptRaisedMidTurnNeedsInputWhileTheTurnIsStillRunning(type: String) throws {
        var rig = try Rig()
        let mark = rig.ask("do the thing")
        rig.push("message.start")
        let kind = type == "clarify.request" ? "clarify" : "approval"
        rig.push(type, ["kind": .string(kind), "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?"])
        guard case .needsInput(let prompt) = rig.transcript.errandOutcome(for: mark) else {
            Issue.record("expected needsInput")
            return
        }
        #expect(prompt.promptID == "p1")
        #expect(rig.transcript.isRunning)
    }

    @Test func aPromptIsOurTurnsOnlyOnceOurMessageWasAdmitted() throws {
        var rig = try Rig()
        rig.push("message.start")
        rig.push("clarify.request", clarify)
        let mark = rig.ask("queued behind a question")
        #expect(rig.transcript.errandOutcome(for: mark) == nil)
    }

    @Test func aPermanentRefusalSurfacesAsFailure() throws {
        var rig = try Rig()
        let mark = rig.ask("nope")
        rig.transcript.markFailed(submissionID: "ask", reason: "permission_denied")
        #expect(rig.transcript.errandOutcome(for: mark) == .failed(.refused(reason: "permission_denied")))
    }

    @Test func aTurnThatEndsWithAnErrorAndNoTextFails() throws {
        var rig = try Rig()
        let mark = rig.ask("break")
        rig.push("message.start")
        rig.push("tool.start", ["tool_id": "t1", "name": "run"])
        rig.push("error", ["message": "model unavailable"])
        rig.push("message.complete", ["text": "", "status": "error"])
        #expect(rig.transcript.errandOutcome(for: mark) == .failed(.turnFailed(message: "model unavailable")))
    }

    @Test func aLaterTurnClosesOursEvenWhileItIsRunning() throws {
        var rig = try Rig()
        let mark = rig.ask("first")
        rig.push("message.start")
        rig.answer("first answer")
        rig.push("message.complete", ["text": "first answer"])
        _ = rig.ask("second", id: "second")
        rig.push("message.start")
        rig.answer("second answer in flight")
        #expect(rig.transcript.isRunning)
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("first answer"))
    }

    @Test func aSnapshotThatReplacesTheEchoStillAttributesTheTurn() throws {
        var rig = try Rig(rows: [("user", "old question"), ("assistant", "old answer")])
        let mark = rig.ask("fresh question")
        let reloaded: JSONValue = [
            "session_id": "s1",
            "messages": [
                ["role": "user", "text": "old question", "row_id": 1],
                ["role": "assistant", "text": "old answer", "row_id": 2],
                ["role": "user", "text": "fresh question", "row_id": 3],
                ["role": "assistant", "text": "fresh answer", "row_id": 4],
            ],
            "running": false, "replay_epoch": "e1", "last_sequence": 9, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        _ = rig.transcript.reconcile(with: try reloaded.decoded(as: SessionSnapshot.self))
        #expect(!rig.transcript.items.contains { $0.id == "submission:ask" })
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("fresh answer"))
    }

    @Test func aSnapshotTakenMidTurnLeavesTheErrandWaiting() throws {
        var rig = try Rig()
        let mark = rig.ask("slow question")
        let reloaded: JSONValue = [
            "session_id": "s1",
            "messages": [["role": "user", "text": "slow question", "row_id": 1]],
            "running": true, "replay_epoch": "e1", "last_sequence": 4, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        _ = rig.transcript.reconcile(with: try reloaded.decoded(as: SessionSnapshot.self))
        #expect(rig.transcript.errandOutcome(for: mark) == nil)
    }
}
