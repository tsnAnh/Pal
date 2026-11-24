import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Testing

extension BotErrandControlTests {
    private var heldDraft: [String: JSONValue] {
        ["question": "Send this message to Sam?", "command": "Running late.", "draft": ["channel": "messages"], "choices": ["once", "deny"]]
    }

    @Test func aDraftFormAnswerGoesToApprovalRespondAndNeverToClarify() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "d1", seq: 3, extra: heldDraft)
        let prompt = try #require(await rig.session.state.transcript.pendingPrompts.first)
        try await rig.session.answerOwnerForm(prompt, answers: [(qid: PendingPrompt.soleQuestionID, answer: .answered("Send"))])
        let sent = rig.script.calls("approval.respond")
        #expect(sent.count == 1)
        #expect(sent[0]["choice"]?.stringValue == "once")
        #expect(sent[0]["prompt_id"]?.stringValue == "d1")
        #expect(sent[0]["edited_text"] == nil)
        #expect(rig.script.calls("clarify.respond").isEmpty)
        #expect(rig.script.calls("clarify.lock").isEmpty)
        await rig.finish()
    }

    @Test func cancellingADraftDeniesIt() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "d1", seq: 3, extra: heldDraft)
        let prompt = try #require(await rig.session.state.transcript.pendingPrompts.first)
        try await rig.session.answerOwnerForm(prompt, answers: [(qid: PendingPrompt.soleQuestionID, answer: .answered("Cancel"))])
        #expect(rig.script.calls("approval.respond").map { $0["choice"]?.stringValue } == ["deny"])
        await rig.finish()
    }

    @Test func anEditedDraftSendsOnceWithTheEditedText() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "d1", seq: 3, extra: heldDraft)
        let prompt = try #require(await rig.session.state.transcript.pendingPrompts.first)
        try await rig.session.answerOwnerEdit(prompt, text: "  Running late, start without me.  ")
        try await rig.session.answerOwnerEdit(prompt, text: "Running late.")
        let sent = rig.script.calls("approval.respond")
        #expect(sent.map { $0["choice"]?.stringValue } == ["once", "once"])
        #expect(sent[0]["edited_text"]?.stringValue == "Running late, start without me.")
        #expect(sent[1]["edited_text"] == nil)
        await rig.finish()
    }

    @Test func aConsentFormCannotBeEditedOrAnsweredWithFreeText() async throws {
        let rig = try await rig()
        try await rig.running()
        try await rig.raise("approval", id: "c1", seq: 3, extra: ["question": "Fill in your saved card?", "command": "Visa 4242", "choices": ["once", "deny"]])
        let prompt = try #require(await rig.session.state.transcript.pendingPrompts.first)
        await #expect(throws: ChatError.self) { try await rig.session.answerOwnerEdit(prompt, text: "anything") }
        await #expect(throws: ChatError.self) {
            try await rig.session.answerOwnerForm(prompt, answers: [(qid: PendingPrompt.soleQuestionID, answer: .answered("Yes please"))])
        }
        await #expect(throws: ChatError.self) {
            try await rig.session.answerOwnerForm(prompt, answers: [(qid: PendingPrompt.soleQuestionID, answer: .skipped)])
        }
        #expect(rig.script.calls("approval.respond").isEmpty)
        try await rig.session.answerOwnerForm(prompt, answers: [(qid: PendingPrompt.soleQuestionID, answer: .answered("Continue"))])
        #expect(rig.script.calls("approval.respond").map { $0["choice"]?.stringValue } == ["once"])
        await rig.finish()
    }

    @Test func attachingToAHeldDraftShowsTheFormAndIgnoresALegacyCommandApproval() async throws {
        let rig = try await rig { script in
            script.override("session.resume") { _ in .result(BotScript().snapshotWithHeldDraft) }
        }
        try await waitUntil("the held draft form", timeout: .seconds(10)) { await rig.session.state.transcript.pendingPrompts.count == 1 }
        let pending = await rig.session.state.transcript.pendingPrompts
        #expect(pending.map(\.promptID) == ["d1"])
        #expect(pending.first?.questions.first?.choices == ["Send", "Edit", "Cancel"])
        await rig.finish()
    }
}
