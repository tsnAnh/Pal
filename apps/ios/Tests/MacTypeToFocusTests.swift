#if os(macOS)
import AppKit
import Testing

@testable import Pal

@MainActor
@Suite("Mac type to focus", .serialized)
struct MacTypeToFocusTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    @MainActor
    private struct Stage {
        let window: KeyWindow
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let monitor = MacTypeToFocusMonitor()
        var focused = 0
        var inserted: [String] = []

        init() {
            window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(field)
            monitor.window = window
        }

        func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            ) ?? NSEvent()
        }
    }

    @Test("a printable key with nothing focused takes the composer and is consumed")
    func printableKeyFocuses() {
        var stage = Stage()
        var focused = 0
        stage.monitor.focusComposer = { focused += 1 }
        #expect(stage.monitor.handle(stage.key("a")))
        #expect(focused == 1)
        stage.window.close()
    }

    @Test("keys that are not typing are left alone", arguments: [
        ("a", [.command] as NSEvent.ModifierFlags), ("c", [.control] as NSEvent.ModifierFlags), ("\r", []), ("\u{1B}", []),
        ("\t", []), (" ", []), ("\u{F700}", []),
    ] as [(String, NSEvent.ModifierFlags)])
    func otherKeysPass(characters: String, modifiers: NSEvent.ModifierFlags) {
        let stage = Stage()
        var focused = 0
        stage.monitor.focusComposer = { focused += 1 }
        #expect(!stage.monitor.handle(stage.key(characters, modifiers: modifiers)))
        #expect(focused == 0)
        stage.window.close()
    }

    @Test("a focused text field keeps its keys, and a blocked chat never steals")
    func neverStealsFromAField() {
        let stage = Stage()
        var focused = 0
        stage.monitor.focusComposer = { focused += 1 }
        stage.window.makeFirstResponder(stage.field)
        #expect(stage.window.firstResponder is NSText)
        #expect(!stage.monitor.handle(stage.key("a")))
        stage.window.makeFirstResponder(nil)
        stage.monitor.isBlocked = { true }
        #expect(!stage.monitor.handle(stage.key("a")))
        #expect(focused == 0)
        stage.window.close()
    }

    @Test("when the composer never takes focus the typed characters still land in the draft")
    func characterIsNotLost() async throws {
        let stage = Stage()
        var inserted: [String] = []
        stage.monitor.insertFallback = { inserted.append($0) }
        #expect(stage.monitor.handle(stage.key("é")))
        try await Task.sleep(for: .milliseconds(400))
        #expect(inserted == ["é"])
        stage.window.close()
    }
}
#endif
