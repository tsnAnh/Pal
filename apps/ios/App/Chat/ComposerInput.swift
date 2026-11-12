import PalChat
import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
import UIKit
#endif

extension EventModifiers {
    var composerModifiers: ComposerModifiers {
        var result: ComposerModifiers = []
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.command) { result.insert(.command) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

@MainActor
enum ComposerInput {
    #if os(macOS)
    static var platform: ComposerPlatform { .mac }

    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    static func insertNewline() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
    #else
    static var platform: ComposerPlatform {
        UIDevice.current.userInterfaceIdiom == .pad && GCKeyboard.coalesced != nil ? .padWithKeyboard : .touch
    }

    static var isComposing: Bool {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.palProbeFirstResponder), to: nil, from: nil, for: nil)
        return (FirstResponderProbe.found as? UITextInput)?.markedTextRange != nil
    }

    static func insertNewline() -> Bool { false }
    #endif
}

#if !os(macOS)
@MainActor
private enum FirstResponderProbe {
    static weak var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func palProbeFirstResponder() {
        FirstResponderProbe.found = self
    }
}
#endif
