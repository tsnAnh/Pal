import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Answer, last reply and spoken text reducers")
struct ErrandAnswerTests {
    private struct Rig {
        var transcript = Transcript()
        var sequence = 0

        init(rows: [(String, String)] = []) throws {
            let messages: [JSONValue] = rows.enumerated().map {
                ["role": .string($1.0), "text": .string($1.1), "row_id": .int($0 + 1)]
            }
            let snapshot: JSONValue = [
                "session_id": "s1", "messages": .array(messages), "running": false, "replay_epoch": "e1",
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

        mutating func ask(_ text: String, id: String = "ask") {
            transcript.echoUser(submissionID: id, text: text)
        }

        mutating func askClarify(_ id: String = "p1") -> PendingPrompt {
            let payload: JSONValue = [
                "kind": "clarify", "prompt_id": .string(id), "execution_generation": 1, "question": "Which flavor?",
                "choices": ["vanilla", "chocolate"],
            ]
            push("clarify.request", payload)
            return transcript.pendingPrompts.first { $0.promptID == id }!
        }

        mutating func say(_ text: String, segment: Int = 0, seal: Bool = true) {
            push("message.delta", ["text": .string(text), "segment": .int(segment), "offset": 0])
            if seal { push("message.interim", ["text": .string(text), "segment": .int(segment)]) }
        }
    }

    @Test func aTurnThatEndsWithoutAnythingToSayIsNoReplyAtAll() throws {
        var rig = try Rig()
        #expect(rig.transcript.lastReply == nil)
        rig.ask("hi")
        rig.push("message.start")
        rig.push("tool.start", ["tool_id": "t1", "name": "run"])
        rig.push("message.complete", ["text": ""])
        #expect(rig.transcript.lastReply == nil)
    }

    @Test func textThatIsStillStreamingIsNotAFinishedReply() throws {
        var rig = try Rig()
        rig.ask("hi")
        rig.push("message.start")
        rig.say("half a thou", seal: false)
        #expect(rig.transcript.lastReply == nil)
        rig.push("message.complete", ["text": "half a thought, finished"])
        #expect(rig.transcript.lastReply == LastReply(text: "half a thought, finished", botIsWorkingOnMore: false))
    }

    @Test func aReplySplitAroundToolCallsIsJoinedAndTheEarlierTurnIsLeftOut() throws {
        var rig = try Rig(rows: [("user", "old"), ("assistant", "old answer")])
        rig.ask("new")
        rig.push("message.start")
        rig.say("Checking.")
        rig.push("tool.start", ["tool_id": "t1", "name": "search"])
        rig.push("tool.complete", ["tool_id": "t1", "name": "search", "summary": "ok"])
        rig.say("It is sunny.", segment: 1, seal: false)
        rig.push("message.complete", ["text": "It is sunny."])
        #expect(rig.transcript.lastReply?.text == "Checking.\n\nIt is sunny.")
    }

    @Test func whileANewTurnHasNoReplyYetTheLastReplyIsTheOlderOneAndWorkIsFlagged() throws {
        var rig = try Rig(rows: [("user", "old"), ("assistant", "old answer")])
        rig.ask("new")
        rig.push("message.start")
        #expect(rig.transcript.lastReply == LastReply(text: "old answer", botIsWorkingOnMore: true))
    }

    @Test func whitespaceOnlyAssistantTextIsIgnored() throws {
        let rig = try Rig(rows: [("user", "hi"), ("assistant", "real"), ("assistant", "   ")])
        #expect(rig.transcript.lastReply?.text == "real")
    }

    @Test func shortTextIsSpokenWhole() {
        let excerpt = SpokenExcerpt("  All done.  ", limit: 50)
        #expect(excerpt == SpokenExcerpt("All done.", limit: 50))
        #expect(!excerpt.isTruncated)
        #expect(excerpt.text == "All done.")
    }

    @Test func longTextIsCutAtASentenceBoundaryWithinTheLimit() {
        let text = "First sentence is here. Second sentence follows right after it. Third one is far too long to fit in."
        let excerpt = SpokenExcerpt(text, limit: 70)
        #expect(excerpt.isTruncated)
        #expect(excerpt.text == "First sentence is here. Second sentence follows right after it.")
        #expect(excerpt.text.count <= 70)
    }

    @Test func aLongRunWithoutSentenceEndsIsCutAtAWordNotMidWord() {
        let text = String(repeating: "alpha beta ", count: 20)
        let excerpt = SpokenExcerpt(text, limit: 40)
        #expect(excerpt.isTruncated)
        #expect(excerpt.text.count <= 40)
        #expect(excerpt.text.hasSuffix("alpha") || excerpt.text.hasSuffix("beta"))
    }

    @Test func textWithoutAnyBreakIsHardCutWithoutSplittingACharacter() {
        let text = String(repeating: "👩‍👩‍👧", count: 30)
        let excerpt = SpokenExcerpt(text, limit: 10)
        #expect(excerpt.isTruncated)
        #expect(excerpt.text.count == 10)
        #expect(excerpt.text == String(repeating: "👩‍👩‍👧", count: 10))
    }

    @Test func theAnswerWaitsWhileTheQuestionIsStillOpen() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        let prompt = rig.askClarify()
        let mark = rig.transcript.answerMark(for: prompt)
        #expect(rig.transcript.errandOutcome(for: mark) == nil)
    }

    @Test func onlyWhatTheBotSaysAfterTheAnswerIsTheReply() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        rig.say("Let me ask you something.")
        let prompt = rig.askClarify()
        let mark = rig.transcript.answerMark(for: prompt)
        rig.push("clarify.settled", ["prompt_id": "p1"])
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "turn still running")
        rig.say("Vanilla it is.", segment: 1, seal: false)
        #expect(rig.transcript.errandOutcome(for: mark) == nil, "still streaming")
        rig.push("message.complete", ["text": "Vanilla it is."])
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("Vanilla it is."))
    }

    @Test func aTurnThatClosesAfterTheAnswerWithoutTextFinishesQuietly() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        let prompt = rig.askClarify()
        let mark = rig.transcript.answerMark(for: prompt)
        rig.push("clarify.settled", ["prompt_id": "p1"])
        rig.push("tool.start", ["tool_id": "t1", "name": "run"])
        rig.push("message.complete", ["text": ""])
        #expect(rig.transcript.errandOutcome(for: mark) == .finishedQuietly)
    }

    @Test func aTurnThatFailsAfterTheAnswerReportsTheFailure() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        let prompt = rig.askClarify()
        let mark = rig.transcript.answerMark(for: prompt)
        rig.push("clarify.settled", ["prompt_id": "p1"])
        rig.push("error", ["message": "model unavailable"])
        rig.push("message.complete", ["text": "", "status": "error"])
        #expect(rig.transcript.errandOutcome(for: mark) == .failed(.turnFailed(message: "model unavailable")))
    }

    @Test func aFollowUpQuestionAfterTheAnswerComesBackAsNeedsInput() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        let first = rig.askClarify("p1")
        let mark = rig.transcript.answerMark(for: first)
        rig.push("clarify.settled", ["prompt_id": "p1"])
        _ = rig.askClarify("p2")
        guard case .needsInput(let next) = rig.transcript.errandOutcome(for: mark) else {
            Issue.record("expected needsInput")
            return
        }
        #expect(next.promptID == "p2")
    }

    @Test func aNewUserTurnAfterTheAnswerDoesNotLeakIntoTheAnswersReply() throws {
        var rig = try Rig()
        rig.ask("pick")
        rig.push("message.start")
        let prompt = rig.askClarify()
        let mark = rig.transcript.answerMark(for: prompt)
        rig.push("clarify.settled", ["prompt_id": "p1"])
        rig.say("Vanilla it is.", segment: 1, seal: false)
        rig.push("message.complete", ["text": "Vanilla it is."])
        rig.ask("another thing", id: "next")
        rig.push("message.start")
        rig.say("unrelated reply", seal: false)
        #expect(rig.transcript.errandOutcome(for: mark) == .replied("Vanilla it is."))
    }

    @Test func spokenAnswersSnapToTheOfferedChoice() throws {
        var rig = try Rig()
        let prompt = rig.askClarify()
        #expect(prompt.canonicalAnswer(for: "Chocolate.") == "chocolate")
        #expect(prompt.canonicalAnswer(for: "  VANILLA ") == "vanilla")
        #expect(prompt.canonicalAnswer(for: "strawberry, please") == "strawberry, please")
    }

    @Test func approvalDecisionsMapToTheGatewaysChoices() {
        let full = PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1, choices: ["once", "session", "always", "deny"])
        let withoutOnce = PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1, choices: ["deny"])
        let bare = PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1)
        #expect(ApprovalDecision.approve.choice(in: full) == "once")
        #expect(ApprovalDecision.deny.choice(in: full) == "deny")
        #expect(ApprovalDecision.approve.choice(in: withoutOnce) == nil)
        #expect(ApprovalDecision.approve.choice(in: bare) == "once")
        #expect(ApprovalDecision.deny.choice(in: bare) == "deny")
    }

    @Test func longCommandsAreShortenedAndFlattenedForSpeech() {
        let long = "rm -rf\n   " + String(repeating: "/very/long/path ", count: 30)
        let prompt = PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1, command: long)
        let spoken = prompt.shortCommand
        #expect(spoken?.hasPrefix("rm -rf /very/long/path") == true)
        #expect(spoken?.hasSuffix("…") == true)
        #expect((spoken?.count ?? 0) <= PendingPrompt.spokenCommandLimit + 1)
        #expect(PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1, command: "  ").shortCommand == nil)
        #expect(PendingPrompt(kind: .approval, promptID: "a", executionGeneration: 1, command: "ls -la").shortCommand == "ls -la")
    }
}
