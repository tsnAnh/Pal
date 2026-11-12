@testable import PalChat
import Testing

@Suite("Composer Return key")
struct ComposerKeysTests {
    private func action(
        _ modifiers: ComposerModifiers = [],
        composing: Bool = false,
        platform: ComposerPlatform = .mac,
        selection: Bool = false
    ) -> ComposerKeyAction {
        ComposerKeys.returnAction(modifiers: modifiers, isComposing: composing, platform: platform, hasCompletionSelection: selection)
    }

    @Test("Return sends; Shift and Option insert a newline; Command sends; Control does nothing", arguments: [ComposerPlatform.mac, .padWithKeyboard])
    func hardwareKeyboard(platform: ComposerPlatform) {
        #expect(action(platform: platform) == .send)
        #expect(action(.shift, platform: platform) == .newline)
        #expect(action(.option, platform: platform) == .newline)
        #expect(action([.shift, .option], platform: platform) == .newline)
        #expect(action([.shift, .command], platform: platform) == .newline)
        #expect(action(.command, platform: platform) == .send)
        #expect(action(.control, platform: platform) == .ignore)
    }

    @Test("Return never sends or edits while an input method is composing", arguments: [ComposerPlatform.mac, .padWithKeyboard])
    func composing(platform: ComposerPlatform) {
        for modifiers: ComposerModifiers in [[], .shift, .option, .command, .control] {
            #expect(action(modifiers, composing: true, platform: platform, selection: true) == .ignore)
        }
    }

    @Test("an open completion takes plain Return only when it has a selection")
    func completion() {
        #expect(action(selection: true) == .acceptCompletion)
        #expect(action(selection: false) == .send)
        #expect(action(.command, selection: true) == .send)
        #expect(action(.shift, selection: true) == .newline)
    }

    @Test("touch keeps the system behaviour: Return is never intercepted")
    func touch() {
        for modifiers: ComposerModifiers in [[], .shift, .option, .command, .control] {
            #expect(action(modifiers, platform: .touch, selection: true) == .ignore)
        }
    }
}
