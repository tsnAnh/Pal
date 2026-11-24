import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Owner decision forms")
struct OwnerDecisionTests {
    private func opened() throws -> Transcript {
        var transcript = Transcript()
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [], "running": false, "replay_epoch": "e1",
            "last_sequence": 1, "execution_generation": 1, "pending": [], "prompts": [],
        ]
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func frame(_ type: String, _ payload: JSONValue, seq: Int) -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: "e1")
    }

    private let draft: JSONValue = [
        "kind": "approval", "prompt_id": "d1", "execution_generation": 1, "question": "Send this message to Sam?",
        "command": "Running late, start without me.", "description": "Message to Sam", "choices": ["once", "deny"],
        "draft": ["channel": "messages"],
    ]

    private let consent: JSONValue = [
        "kind": "approval", "prompt_id": "c1", "execution_generation": 1, "question": "Fill in your saved card on this page?",
        "command": "Visa ending 4242", "choices": ["once", "deny"],
    ]

    private func form(_ transcript: Transcript, _ promptID: String) -> (prompt: PendingPrompt, choices: [String])? {
        for item in transcript.items {
            if case .clarify(let card) = item.content, card.prompt.promptID == promptID {
                return (card.prompt, card.prompt.questions.first?.choices ?? [])
            }
        }
        return nil
    }

    @Test func aHeldDraftIsTheClarifyFormWithSendEditCancel() throws {
        var transcript = try opened()
        #expect(transcript.apply(frame("approval.request", draft, seq: 2)) == .applied)
        let shown = try #require(form(transcript, "d1"))
        #expect(shown.choices == ["Send", "Edit", "Cancel"])
        #expect(shown.prompt.kind == .approval)
        #expect(shown.prompt.questions.count == 1)
        #expect(shown.prompt.questions[0].question == "Send this message to Sam?")
        #expect(shown.prompt.editableText == "Running late, start without me.")
        #expect(transcript.pendingPrompts.map(\.promptID) == ["d1"])
        #expect(transcript.ignoredPromptIDs.isEmpty)
    }

    @Test func aHeldDraftShowsTheLabelsTheGatewayChoseForTheConversationLanguage() throws {
        var transcript = try opened()
        let vietnamese: JSONValue = [
            "kind": "approval", "prompt_id": "d2", "execution_generation": 1, "question": "Gửi tin nhắn này?",
            "command": "Tôi đến trễ.", "choices": ["once", "deny"], "draft": ["channel": "messages", "editable": true],
            "labels": ["send": "Gửi", "edit": "Sửa", "cancel": "Hủy"],
        ]
        #expect(transcript.apply(frame("approval.request", vietnamese, seq: 2)) == .applied)
        let shown = try #require(form(transcript, "d2"))
        #expect(shown.choices == ["Gửi", "Sửa", "Hủy"])
        #expect(shown.prompt.ownerChoice(forLabel: "Gửi") == "once")
        #expect(shown.prompt.ownerChoice(forLabel: "Hủy") == "deny")
        #expect(shown.prompt.ownerChoice(forLabel: "Sửa") == nil)
    }

    @Test func aMoneyConsentIsTheClarifyFormWithContinueCancelAndNoEdit() throws {
        var transcript = try opened()
        _ = transcript.apply(frame("approval.request", consent, seq: 2))
        let shown = try #require(form(transcript, "c1"))
        #expect(shown.choices == ["Continue", "Cancel"])
        #expect(shown.prompt.editableText == nil)
        #expect(shown.prompt.ownerChoice(forLabel: "Continue") == "once")
        #expect(shown.prompt.ownerChoice(forLabel: "Cancel") == "deny")
        #expect(shown.prompt.ownerChoice(forLabel: "Edit") == nil)
    }

    @Test func aLegacyCommandApprovalWithoutAQuestionShowsNothing() throws {
        var transcript = try opened()
        let legacy: JSONValue = [
            "kind": "approval", "prompt_id": "old", "execution_generation": 1, "command": "rm -rf build",
            "description": "recursive delete", "choices": ["once", "session", "always", "deny"],
        ]
        #expect(transcript.apply(frame("approval.request", legacy, seq: 2)) == .applied)
        #expect(transcript.items.isEmpty)
        #expect(transcript.pendingPrompts.isEmpty)
        #expect(transcript.ignoredPromptIDs == ["old"])
        let blank: JSONValue = ["kind": "approval", "prompt_id": "blank", "execution_generation": 1, "question": "  ", "command": "ls"]
        _ = transcript.apply(frame("approval.request", blank, seq: 3))
        #expect(transcript.items.isEmpty)
    }

    @Test func aSettledApprovalRemovesTheForm() throws {
        var transcript = try opened()
        _ = transcript.apply(frame("approval.request", draft, seq: 2))
        _ = transcript.apply(frame("approval.request", consent, seq: 3))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["d1", "c1"])
        _ = transcript.apply(frame("approval.settled", ["prompt_id": "d1"], seq: 4))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["c1"])
        _ = transcript.apply(frame("approval.settled", ["prompt_id": "c1"], seq: 5))
        #expect(transcript.items.isEmpty)
    }

    @Test func aSnapshotCarriesTheSameFormAndDropsLegacyApprovals() throws {
        var transcript = Transcript()
        let snapshot: JSONValue = [
            "session_id": "s1", "messages": [], "running": true, "replay_epoch": "e1", "last_sequence": 5,
            "execution_generation": 1, "pending": [], "prompts": [draft, ["kind": "approval", "prompt_id": "old", "command": "ls"]],
        ]
        _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
        #expect(transcript.pendingPrompts.map(\.promptID) == ["d1"])
        #expect(transcript.ignoredPromptIDs == ["old"])
    }
}
