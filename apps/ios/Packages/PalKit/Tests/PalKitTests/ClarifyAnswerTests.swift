import Testing
import PalChat

struct ClarifyAnswerTests {
    private let choices = ["red", "green", "blue"]

    @Test func blankTypedTextIsNeverAnAnswer() {
        #expect(ClarifyAnswer.compose(choices: choices, selection: [], typed: "  \n", multiSelect: false) == nil)
        #expect(ClarifyAnswer.compose(choices: choices, selection: [], typed: "", multiSelect: true) == nil)
    }

    @Test func singleSelectSendsTrimmedText() {
        #expect(ClarifyAnswer.compose(choices: choices, selection: [0], typed: " mint ", multiSelect: false) == "mint")
    }

    @Test func multiSelectWithoutTextKeepsIndexAnswer() {
        #expect(ClarifyAnswer.compose(choices: choices, selection: [2, 0], typed: "", multiSelect: true) == "1,3")
    }

    @Test func multiSelectAddsTypedTextAsExtraAnswer() {
        #expect(ClarifyAnswer.compose(choices: choices, selection: [1], typed: "mint", multiSelect: true) == #"["green","mint"]"#)
        #expect(ClarifyAnswer.compose(choices: choices, selection: [], typed: "mint", multiSelect: true) == #"["mint"]"#)
    }
}
