import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Settled clarify record")
struct ClarifySettledTests {
    private static let questions = [
        ClarifyQuestion(qid: "q0", question: "Platforms?", choices: ["Mac", "iPhone", "iPad"]),
        ClarifyQuestion(qid: "q1", question: "Mockups first?", choices: ["Setup", "Connect Apps", "Kanban"], multiSelect: true),
        ClarifyQuestion(qid: "q2", question: "Anything else?"),
        ClarifyQuestion(qid: "q3", question: "Who may use it?", choices: ["Only me", "Anyone"]),
    ]

    private func answeredForm() -> ClarifyForm {
        var form = ClarifyForm(questions: Self.questions)
        form.pick(1)
        form.advance()
        form.pick(2)
        form.pick(0)
        form.advance()
        form.setTyped("  dark mode  ")
        form.advance()
        form.skip()
        return form
    }

    @Test func recordsBecomeOneEntryEachWithOnlyTheChosenRows() {
        let settled = ClarifySettled(records: [
            ClarifyRecord(question: "Which flavor?", answer: .answered(["chocolate"])),
            ClarifyRecord(question: "Toppings?", answer: .answered(["a", "c"])),
        ])
        #expect(settled.entries == [
            .init(question: "Which flavor?", chosen: ["chocolate"]),
            .init(question: "Toppings?", chosen: ["a", "c"]),
        ])
        #expect(!settled.isSingle)
    }

    @Test func aSkippedOrEmptyAnswerHasNoChosenRow() {
        let settled = ClarifySettled(records: [
            ClarifyRecord(question: "A?", answer: .skipped),
            ClarifyRecord(question: "B?", answer: .answered(["", ""])),
        ])
        let skipped = settled.entries.map { $0.isSkipped }
        #expect(skipped == [true, true])
    }

    @Test func aFormOnlyKeepsTheChosenLabelsTypedTextAndSkips() throws {
        let settled = try #require(ClarifySettled(form: answeredForm()))
        let questions = settled.entries.map { $0.question }
        #expect(questions == ["Platforms?", "Mockups first?", "Anything else?", "Who may use it?"])
        #expect(settled.entries[0].chosen == ["iPhone"])
        #expect(settled.entries[1].chosen == ["Setup", "Kanban"])
        #expect(settled.entries[2].chosen == ["dark mode"])
        #expect(settled.entries[3].isSkipped)
    }

    @Test func aFormWithAnUnansweredPageDoesNotSettle() {
        var form = ClarifyForm(questions: Self.questions)
        form.pick(0)
        #expect(ClarifySettled(form: form) == nil)
    }

    @Test func aTypedOtherAnswerReplacesTheSingleChoicePick() throws {
        var form = ClarifyForm(questions: [Self.questions[0]])
        form.pick(1)
        form.setTyped("Watch")
        let settled = try #require(ClarifySettled(form: form))
        #expect(settled.entries[0].chosen == ["Watch"])
    }

    @Test func aMultiSelectKeepsEveryPickAndTheTypedRow() throws {
        var form = ClarifyForm(questions: [Self.questions[1]])
        form.pick(0)
        form.pick(2)
        form.setTyped("Other")
        let settled = try #require(ClarifySettled(form: form))
        #expect(settled.entries[0].chosen == ["Setup", "Kanban", "Other"])
    }

    @Test func theSettledFormMatchesWhatTheSameFormSendsToTheBot() throws {
        let form = answeredForm()
        let wire = try #require(form.payload).map(\.answer)
        let settled = try #require(ClarifySettled(form: form))
        for (index, answer) in wire.enumerated() {
            switch answer {
            case .skipped:
                let entry = settled.entries[index]
                #expect(entry.isSkipped)
            case .answered(let text):
                let entry = settled.entries[index]
                let carriesPick = !entry.isSkipped && text.contains(entry.chosen[0])
                #expect(carriesPick)
            }
        }
    }

    @Test func ownerDecisionsShowTheChosenOptionOnly() {
        let sent = ClarifySettled(question: "Send this message?", option: .send)
        let cancelled = ClarifySettled(question: "Send this message?", option: .cancel)
        #expect(sent.entries == [.init(question: "Send this message?", chosen: [OwnerOption.send.label])])
        #expect(cancelled.entries[0].chosen == [OwnerOption.cancel.label])
        #expect(sent.isSingle)
    }

    @Test func aSingleQuestionAnswerFromTheLegacyCardIsOneChosenRowOrSkipped() {
        #expect(ClarifySettled(question: "Q?", answer: "yes").entries[0].chosen == ["yes"])
        #expect(ClarifySettled(question: "Q?", answer: "").entries[0].isSkipped)
        #expect(ClarifySettled(question: "Q?", answer: nil).entries[0].isSkipped)
    }

    @Test func historyAndLiveAnswersRestoreToTheSameSettledRecord() throws {
        let json = """
        {"responses": [
          {"question": "Which flavor?", "choices_offered": ["vanilla", "chocolate"], "status": "answered", "user_response": "chocolate"},
          {"question": "Toppings?", "choices_offered": ["a", "b"], "status": "skipped", "user_response": null}
        ], "outcome": "submitted"}
        """
        var transcript = Transcript()
        let snapshot: JSONValue = [
            "session_id": "s1", "replay_epoch": "e1", "last_sequence": 0,
            "messages": [["role": "tool", "name": "clarify", "tool_call_id": "t1", "text": .string(json), "row_id": 2]],
        ]
        transcript.load(try snapshot.decoded(as: SessionSnapshot.self))
        let records = transcript.items.compactMap { item -> ClarifyRecord? in
            if case .clarifyAnswered(let record) = item.content { record } else { nil }
        }
        let settled = ClarifySettled(records: records)
        #expect(settled.entries == [
            .init(question: "Which flavor?", chosen: ["chocolate"]),
            .init(question: "Toppings?", chosen: []),
        ])
    }
}
