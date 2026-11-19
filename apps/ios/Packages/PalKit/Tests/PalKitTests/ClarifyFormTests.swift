import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Clarify paged form")
struct ClarifyFormTests {
    private static let questions = [
        ClarifyQuestion(qid: "q0", question: "Platforms?", choices: ["Mac", "iPhone", "iPad"]),
        ClarifyQuestion(qid: "q1", question: "Mockups first?", choices: ["Setup", "Connect Apps", "Kanban"], multiSelect: true),
        ClarifyQuestion(qid: "q2", question: "Anything else?"),
        ClarifyQuestion(qid: "q3", question: "Who may use it?", choices: ["Only me", "Anyone"]),
    ]

    private func form() -> ClarifyForm { ClarifyForm(questions: Self.questions) }

    @Test func startsOnTheFirstPageWithDotsAndNothingAnswered() {
        let form = form()
        #expect(form.page == 0 && form.count == 4 && form.isFirst && !form.isLast && form.showsPaging)
        #expect(!form.canAdvance && !form.canSubmit && form.payload == nil)
    }

    @Test func nextStaysDisabledUntilThePageIsAnsweredOrSkipped() {
        var form = form()
        #expect(form.advance() == false && form.page == 0)
        form.pick(1)
        #expect(form.canAdvance)
        #expect(form.advance() && form.page == 1)
        #expect(!form.canAdvance)
        form.skip()
        #expect(form.canAdvance)
    }

    @Test func backKeepsEveryAnswer() {
        var form = form()
        form.pick(2)
        form.advance()
        form.pick(0)
        form.pick(2)
        #expect(form.back() && form.page == 0)
        #expect(form.currentDraft.picked == [2])
        form.advance()
        #expect(form.currentDraft.picked == [0, 2])
        #expect(form.back() && !form.back())
    }

    @Test func singleSelectPickReplacesThePickAndClearsTypedText() {
        var form = form()
        form.pick(0)
        form.pick(2)
        #expect(form.currentDraft.picked == [2])
        form.setTyped("Watch")
        #expect(form.currentDraft.picked.isEmpty)
        #expect(form.answer(at: 0) == .answered("Watch"))
        form.pick(1)
        #expect(form.currentDraft.typed.isEmpty)
        #expect(form.answer(at: 0) == .answered("iPhone"))
    }

    @Test func multiSelectTogglesAndKeepsTypedTextAlongsidePicks() {
        var form = form()
        form.pick(0)
        form.advance()
        form.pick(0)
        form.pick(2)
        form.pick(0)
        #expect(form.currentDraft.picked == [2])
        form.pick(0)
        form.setTyped("Settings")
        #expect(form.answer(at: 1) == .answered(#"["Setup","Kanban","Settings"]"#))
    }

    @Test func multiSelectSendsLabelsNotIndices() {
        #expect(ClarifyAnswer.wire(choices: ["a", "b", "c"], selection: [0, 2], typed: "", multiSelect: true) == #"["a","c"]"#)
        #expect(ClarifyAnswer.compose(choices: ["a", "b", "c"], selection: [0, 2], typed: "", multiSelect: true) == "1,3")
        #expect(ClarifyAnswer.wire(choices: ["a"], selection: [], typed: "  ", multiSelect: true) == nil)
        #expect(ClarifyAnswer.wire(choices: ["a", "b"], selection: [1], typed: "", multiSelect: false) == "b")
        #expect(ClarifyAnswer.wire(choices: ["a", "b"], selection: [1], typed: " mine ", multiSelect: false) == "mine")
    }

    @Test func openEndedQuestionAnswersWithTypedTextOnly() {
        var form = form()
        form.pick(0)
        form.advance()
        form.pick(1)
        form.advance()
        #expect(!form.hasChoices && !form.canAdvance)
        form.pick(0)
        #expect(!form.canAdvance)
        form.setTyped("   ")
        #expect(!form.canAdvance)
        form.setTyped("Keep it read-only")
        #expect(form.canAdvance)
    }

    @Test func skipClearsThePageAndTypingOrPickingUndoesTheSkip() {
        var form = form()
        form.pick(1)
        form.skip()
        #expect(form.currentDraft == ClarifyForm.Draft(skipped: true))
        #expect(form.answer(at: 0) == .skipped)
        form.pick(1)
        #expect(!form.currentDraft.skipped && form.answer(at: 0) == .answered("iPhone"))
        form.skip()
        form.setTyped("other")
        #expect(!form.currentDraft.skipped)
    }

    @Test func lastPageSubmitsEveryAnswerInQuestionOrderWithSkippedAsSkipped() throws {
        var form = form()
        form.pick(0)
        form.advance()
        form.pick(0)
        form.pick(2)
        form.advance()
        form.skip()
        form.advance()
        #expect(form.isLast && !form.canSubmit)
        form.pick(1)
        #expect(form.canSubmit)
        let payload = try #require(form.payload)
        #expect(payload.map(\.qid) == ["q0", "q1", "q2", "q3"])
        #expect(payload.map(\.answer) == [.answered("Mac"), .answered(#"["Setup","Kanban"]"#), .skipped, .answered("Anyone")])
    }

    @Test func recapCountsAnsweredAndSkippedPages() {
        var form = form()
        form.pick(0)
        form.advance()
        form.skip()
        #expect(form.recap.answered == 1 && form.recap.skipped == 1)
    }

    @Test func backAfterClearingAnAnswerBlocksSubmitUntilItIsAnsweredAgain() {
        var form = form()
        form.pick(0)
        form.advance()
        form.pick(0)
        form.advance()
        form.skip()
        form.advance()
        form.pick(0)
        #expect(form.canSubmit)
        form.back()
        form.back()
        form.pick(0)
        #expect(!form.canSubmit && form.payload == nil)
    }

    @Test func aSingleQuestionFormHasNoPagingAndPassesTheAnswerThrough() throws {
        var form = ClarifyForm(questions: [ClarifyQuestion(qid: "q0", question: "Merge it now?", choices: ["Yes", "Not yet"])])
        #expect(!form.showsPaging && form.isFirst && form.isLast)
        form.pick(1)
        #expect(try #require(form.payload).map(\.answer) == [.answered("Not yet")])
    }

    @Test func letterKeysMapToChoiceIndices() {
        #expect(ClarifyForm.choiceIndex(forLetter: "a") == 0)
        #expect(ClarifyForm.choiceIndex(forLetter: "D") == 3)
        #expect(ClarifyForm.choiceIndex(forLetter: "1") == nil)
        #expect(ClarifyForm.letter(2) == "C")
    }

    @Test func pickingOutsideTheChoicesDoesNothing() {
        var form = form()
        form.pick(7)
        #expect(form.currentDraft == ClarifyForm.Draft())
    }
}
