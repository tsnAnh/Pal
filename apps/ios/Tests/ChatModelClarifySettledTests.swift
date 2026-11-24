import Foundation
import PalProtocol
import Testing

@testable import Pal
@testable import PalChat

@MainActor
@Suite("An answered question card settles in the list")
struct ChatModelClarifySettledTests {
    private let prompt = PendingPrompt(
        kind: .clarify, promptID: "srq-1", executionGeneration: 1, question: "Mac or iPhone?", multiSelect: false,
        questions: [ClarifyQuestion(qid: "q0", question: "Mac or iPhone?", choices: ["Mac", "iPhone"])]
    )

    private func openWorld() -> RebuildWorld {
        var world = RebuildWorld()
        world.append(rebuildUser("u1", "ask me", at: rebuildAt(0)))
        world.append(TranscriptItem(id: "prompt:srq-1", content: .clarify(PromptCard(prompt: prompt)), timestamp: rebuildAt(5)))
        return world
    }

    @Test("accepting the answer republishes the row as settled with no new snapshot and no reload")
    func settlesWithoutASnapshot() throws {
        let model = try rebuildChatModel()
        let world = openWorld()
        model.apply(world.snapshot(version: 1))
        #expect(model.rows.last?.kind == .clarify(prompt))
        #expect(model.windowRows.last?.kind == .clarify(prompt))
        let rowsBefore = model.rows.map(\.id)

        model.markSettled(prompt, ClarifySettled(question: "Mac or iPhone?", answer: "Mac"), since: .now)

        let settled = ChatRow.Kind.clarifyAnswered([ClarifyRecord(question: "Mac or iPhone?", answer: .answered(["Mac"]))])
        #expect(model.rows.last?.kind == settled)
        #expect(model.windowRows.last?.kind == settled)
        let rowsAfter = model.rows.map { $0.id }
        #expect(rowsAfter == rowsBefore)
        #expect(model.windowRowIDs == model.rowIDs)
    }

    @Test("a multi-question form settles to one row holding every question")
    func formSettlesToOneBlock() throws {
        let form = PendingPrompt(
            kind: .clarify, promptID: "srq-2", executionGeneration: 1,
            questions: [ClarifyQuestion(qid: "q0", question: "A?", choices: ["x"]), ClarifyQuestion(qid: "q1", question: "B?")]
        )
        var world = RebuildWorld()
        world.append(TranscriptItem(id: "prompt:srq-2", content: .clarify(PromptCard(prompt: form)), timestamp: rebuildAt(0)))
        let model = try rebuildChatModel()
        model.apply(world.snapshot(version: 1))

        model.markSettled(form, ClarifySettled(entries: [.init(question: "A?", chosen: ["x"]), .init(question: "B?", chosen: [])]), since: .now)

        guard case .clarifyAnswered(let records)? = model.windowRows.last?.kind else {
            Issue.record("the form row did not settle")
            return
        }
        #expect(records == [ClarifyRecord(question: "A?", answer: .answered(["x"])), ClarifyRecord(question: "B?", answer: .skipped)])
    }

    @Test("the outbound send card settles to the chosen option")
    func sendCardSettles() throws {
        let draft = PendingPrompt(
            kind: .approval, promptID: "d1", executionGeneration: 1, choices: ["once", "deny"], question: "Send this message?",
            command: "hi", draft: ["channel": "messages"],
            questions: [ClarifyQuestion(qid: PendingPrompt.soleQuestionID, question: "Send this message?", choices: ["Send", "Edit", "Cancel"])]
        )
        var world = RebuildWorld()
        world.append(TranscriptItem(id: "prompt:d1", content: .clarify(PromptCard(prompt: draft)), timestamp: rebuildAt(0)))
        let model = try rebuildChatModel()
        model.apply(world.snapshot(version: 1))

        model.markSettled(draft, ClarifySettled(question: "Send this message?", option: .send), since: .now)

        #expect(model.windowRows.last?.kind == .clarifyAnswered([ClarifyRecord(question: "Send this message?", answer: .answered([OwnerOption.send.label]))]))
    }

    @Test("the follow-up bot rows and a later snapshot keep the settled card")
    func followUpRowsKeepIt() throws {
        let model = try rebuildChatModel()
        var world = openWorld()
        model.apply(world.snapshot(version: 1))
        model.markSettled(prompt, ClarifySettled(question: "Mac or iPhone?", answer: "Mac"), since: .now)

        world.append(rebuildAssistant("a1", "Mac it is.", at: rebuildAt(10)))
        model.apply(world.snapshot(version: 2))

        let shownIDs = model.windowRows.map { $0.id }
        #expect(shownIDs == model.rowIDs)
        #expect(model.rows.count == 3)
        let kinds = model.windowRows.map(\.kind)
        let hasSettled = kinds.contains { if case .clarifyAnswered = $0 { true } else { false } }
        let hasReply = kinds.contains { if case .assistant = $0 { true } else { false } }
        #expect(hasSettled)
        #expect(hasReply)
    }

    @Test("the jump button hides while the newest row is a question card")
    func jumpButtonHidesOverACard() throws {
        let model = try rebuildChatModel()
        model.apply(openWorld().snapshot(version: 1))
        #expect(model.newestRowIsQuestion)
        #expect(!ChatJumpButtonPolicy.shows(scrollWants: true, finding: false, newestIsQuestion: model.newestRowIsQuestion))
        var world = openWorld()
        world.append(rebuildAssistant("a1", "done", at: rebuildAt(10)))
        model.apply(world.snapshot(version: 2))
        #expect(!model.newestRowIsQuestion)
        #expect(ChatJumpButtonPolicy.shows(scrollWants: true, finding: false, newestIsQuestion: model.newestRowIsQuestion))
        #expect(!ChatJumpButtonPolicy.shows(scrollWants: true, finding: true, newestIsQuestion: false))
    }
}
