import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Clarify form auto-advance")
struct ClarifyFormAutoAdvanceTests {
    private static let questions = [
        ClarifyQuestion(qid: "q0", question: "Platforms?", choices: ["Mac", "iPhone", "iPad"]),
        ClarifyQuestion(qid: "q1", question: "Mockups first?", choices: ["Setup", "Connect Apps", "Kanban"], multiSelect: true),
        ClarifyQuestion(qid: "q2", question: "Anything else?"),
        ClarifyQuestion(qid: "q3", question: "Who may use it?", choices: ["Only me", "Anyone"]),
    ]

    private func form() -> ClarifyForm { ClarifyForm(questions: Self.questions) }

    @Test func singlePickOnAMiddlePageAdvancesByItself() {
        var form = form()
        #expect(form.choose(1) == .advanced)
        #expect(form.page == 1 && form.phase == .answering)
        #expect(form.answer(at: 0) == .answered("iPhone"))
    }

    @Test func singlePickOnTheLastPageReportsReadyToSubmitExactlyOnce() throws {
        var form = form()
        form.pick(0)
        form.advance()
        form.pick(0)
        form.advance()
        form.skip()
        form.advance()
        #expect(form.isLast)
        #expect(form.choose(1) == .submit)
        #expect(form.isSending)
        #expect(try #require(form.payload).map(\.qid) == ["q0", "q1", "q2", "q3"])
        #expect(form.choose(0) == .ignored)
        #expect(form.confirm() == .ignored)
        #expect(form.answer(at: 3) == .answered("Anyone"))
    }

    @Test func multiSelectAndTextPagesDoNotAdvanceOnPick() {
        var form = form()
        form.pick(0)
        form.advance()
        #expect(form.choose(0) == .stayed && form.page == 1)
        #expect(form.confirm() == .advanced && form.page == 2)
        #expect(form.choose(0) == .ignored)
        form.setTyped("Keep it read-only")
        #expect(form.confirm() == .advanced && form.page == 3)
    }

    @Test func confirmWithoutAnAnswerIsIgnored() {
        var form = form()
        #expect(form.confirm() == .ignored && form.page == 0)
    }

    @Test func backThenPickAnotherOptionAdvancesAndKeepsLaterAnswers() {
        var form = form()
        form.choose(0)
        form.pick(1)
        form.confirm()
        form.back()
        form.back()
        #expect(form.page == 0 && form.currentDraft.picked == [0])
        #expect(form.choose(2) == .advanced && form.page == 1)
        #expect(form.answer(at: 0) == .answered("iPad"))
        #expect(form.answer(at: 1) == .answered(#"["Connect Apps"]"#))
    }

    @Test func pickingTheSameOptionAgainAdvancesWithoutChangingTheAnswer() {
        var form = form()
        form.choose(1)
        form.back()
        #expect(form.choose(1) == .advanced && form.page == 1)
        #expect(form.answer(at: 0) == .answered("iPhone"))
    }

    @Test func changingAnEarlierAnswerNeverSubmitsBeforeTheLastPage() {
        var form = form()
        form.choose(0)
        form.pick(0)
        form.confirm()
        form.setTyped("note")
        form.confirm()
        #expect(form.isLast)
        form.jump(to: 0)
        #expect(form.choose(2) == .advanced && !form.isSending && form.page == 1)
    }

    @Test func dotsJumpToAnsweredPagesOnly() {
        var form = form()
        form.choose(0)
        #expect(form.canJump(to: 0) && !form.canJump(to: 1) && !form.canJump(to: 3))
        form.pick(0)
        form.confirm()
        #expect(form.jump(to: 0) && form.page == 0)
        #expect(form.canJump(to: 1) && !form.canJump(to: 2))
        #expect(!form.jump(to: 2) && form.page == 0)
    }

    @Test func skippingAPageAdvancesAndSkippingTheLastPageSubmits() {
        var form = form()
        #expect(form.skipPage() == .advanced && form.page == 1)
        #expect(form.answer(at: 0) == .skipped)
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        #expect(form.isLast && form.skipPage() == .submit && form.isSending)
    }

    @Test func nothingChangesWhileSending() {
        var form = form()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        #expect(form.choose(0) == .submit)
        let frozen = form
        form.pick(1)
        form.setTyped("late")
        form.skip()
        #expect(!form.back() && !form.advance() && !form.jump(to: 0))
        #expect(form == frozen)
    }

    @Test func aFailedSubmitKeepsEveryAnswerAndWaitsForARetry() throws {
        var form = form()
        form.choose(0)
        form.pick(0)
        form.confirm()
        form.setTyped("note")
        form.confirm()
        #expect(form.choose(1) == .submit)
        let answers = try #require(form.payload).map(\.answer)
        form.submitFailed(URLError(.notConnectedToInternet))
        #expect(form.phase == .failed("You are offline.") && form.failure == "You are offline.")
        #expect(form.page == 3 && !form.isSending)
        #expect(try #require(form.payload).map(\.answer) == answers)
        #expect(form.retry() == .submit && form.isSending)
        #expect(form.retry() == .ignored)
    }

    @Test func aFailedSubmitReturnsToTheLastPage() {
        var form = form()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.choose(0)
        form.submitFailed(ChatError.notConnected)
        #expect(form.page == 3 && form.failure == "Pal is not connected right now.")
    }

    @Test func changingTheAnswerAfterAFailureSubmitsOnceMore() {
        var form = form()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.choose(0)
        form.submitFailed(RPCError(code: 500, message: "Gateway said no"))
        #expect(form.failure == "Gateway said no")
        #expect(form.choose(1) == .submit && form.failure == nil)
    }

    @Test func goingBackAfterAFailureClearsTheFailure() {
        var form = form()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.skip()
        form.advance()
        form.choose(0)
        form.submitFailed(ChatError.clarifyExpired)
        #expect(form.back() && form.failure == nil)
    }

    @Test func submitFailedOutsideASendIsIgnored() {
        var form = form()
        form.submitFailed(ChatError.notConnected)
        #expect(form.phase == .answering)
    }

    @Test func aSingleQuestionFormSubmitsOnTheFirstTap() {
        var form = ClarifyForm(questions: [ClarifyQuestion(qid: "q0", question: "Merge it now?", choices: ["Yes", "Not yet"])])
        #expect(form.choose(0) == .submit)
    }
}
