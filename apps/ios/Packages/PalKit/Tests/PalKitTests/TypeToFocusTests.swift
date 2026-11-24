import Testing

@testable import PalChat

struct TypeToFocusTests {
    private func insertion(
        _ characters: String, _ modifiers: TypeToFocus.Modifiers = [], focused: Bool = false, blocked: Bool = false
    ) -> String? {
        TypeToFocus.insertion(characters: characters, modifiers: modifiers, textInputFocused: focused, blocked: blocked)
    }

    @Test(arguments: ["a", "A", "7", "?", "😀", "ab c", "é"])
    func printableTextIsInserted(_ characters: String) {
        #expect(insertion(characters) == characters)
    }

    @Test func optionAloneStillTypes() {
        #expect(insertion("å", .option) == "å")
    }

    @Test(arguments: [" ", "  ", "\u{00A0}", "\n "])
    func whitespaceOnlyIsLeftAlone(_ characters: String) {
        #expect(insertion(characters) == nil)
    }

    @Test(arguments: ["\r", "\u{1B}", "\t", "\u{F700}", "\u{F704}", "\u{7F}", "\u{8}", "\u{3}", "a\u{1B}", "\u{F8FF}"])
    func controlAndFunctionKeysAreLeftAlone(_ characters: String) {
        #expect(insertion(characters) == nil)
    }

    @Test func commandAndControlAreLeftAlone() {
        #expect(insertion("v", .command) == nil)
        #expect(insertion("a", .control) == nil)
        #expect(insertion("a", [.option, .command]) == nil)
    }

    @Test func focusedInputOrBlockedIsLeftAlone() {
        #expect(insertion("a", focused: true) == nil)
        #expect(insertion("a", blocked: true) == nil)
    }

    @Test func emptyIsLeftAlone() {
        #expect(insertion("") == nil)
    }
}
