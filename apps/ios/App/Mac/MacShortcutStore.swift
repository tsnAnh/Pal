#if os(macOS)
import PalSettings
import SwiftUI

@MainActor
@Observable
final class ShortcutStore {
    static let defaultsKey = "mac.shortcuts.bindings"

    private(set) var bindings: ShortcutBindings

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = ShortcutBindings(decoding: defaults.data(forKey: Self.defaultsKey))
    }

    func chord(for action: ShortcutAction) -> KeyChord? { bindings.chord(for: action) }

    func assign(_ chord: KeyChord, to action: ShortcutAction) { update { $0.assign(chord, to: action) } }
    func clear(_ action: ShortcutAction) { update { $0.clear(action) } }
    func reset(_ action: ShortcutAction) { update { $0.reset(action) } }
    func resetAll() { update { $0.resetAll() } }

    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        chord(for: action).flatMap(Self.keyboardShortcut)
    }

    func accessibilityLabel(for action: ShortcutAction) -> String {
        let current = chord(for: action)?.spoken ?? String(localized: "None")
        return String(localized: "\(String(localized: action.localizedTitle)), shortcut \(current)")
    }

    private func update(_ change: (inout ShortcutBindings) -> Void) {
        var next = bindings
        change(&next)
        guard next != bindings else { return }
        bindings = next
        if let data = next.encoded(), next.hasCustomizations {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    static func keyboardShortcut(_ chord: KeyChord) -> KeyboardShortcut? {
        guard let key = keyEquivalent(chord.key) else { return nil }
        return KeyboardShortcut(key, modifiers: eventModifiers(chord.modifiers))
    }

    static func eventModifiers(_ modifiers: ChordModifiers) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func keyEquivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "home": return .home
        case "end": return .end
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        default: break
        }
        if let number = KeyChord.functionNumber(key), let scalar = Unicode.Scalar(0xF703 + number) {
            return KeyEquivalent(Character(scalar))
        }
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }
}

extension ShortcutAction {
    var localizedTitle: String.LocalizationValue {
        switch self {
        case .newBot: "New Bot"
        case .search: "Search"
        case .searchAlternate: "Search in All Chats"
        case .settings: "Settings…"
        case .shortcuts: "Keyboard Shortcuts"
        case .focusComposer: "Focus Message Field"
        case .findInChat: "Find in Chat"
        case .previousBot: "Previous Bot"
        case .nextBot: "Next Bot"
        case .compactSidebar: "Compact Sidebar"
        case .details: "Bot Details"
        case .connectApps: "Connect Apps"
        }
    }
}

extension ShortcutGroup {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .chat: "Chat"
        case .bots: "Bots"
        case .view: "View"
        }
    }
}
#endif
