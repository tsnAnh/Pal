import Foundation

public struct ChordModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ChordModifiers(rawValue: 1)
    public static let option = ChordModifiers(rawValue: 2)
    public static let shift = ChordModifiers(rawValue: 4)
    public static let command = ChordModifiers(rawValue: 8)

    static let symbols: [(ChordModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
}

public struct KeyChord: Codable, Sendable, Hashable {
    public let key: String
    public let modifiers: ChordModifiers

    public init(key: String, modifiers: ChordModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let namedKeys: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩", "tab": "⇥", "space": "Space",
        "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
    ]

    public var isFunctionKey: Bool { Self.functionNumber(key) != nil }
    public var isPrintable: Bool { Self.namedKeys[key] == nil && !isFunctionKey }

    public static func functionNumber(_ key: String) -> Int? {
        guard key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number) else { return nil }
        return number
    }

    public var glyphs: [String] {
        let symbols = ChordModifiers.symbols.filter { modifiers.contains($0.0) }.map(\.1)
        return symbols + [keyGlyph]
    }

    public var keyGlyph: String {
        if let named = Self.namedKeys[key] { return named }
        if let number = Self.functionNumber(key) { return "F\(number)" }
        return key.uppercased()
    }

    public var spoken: String {
        let names = [(ChordModifiers.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
            .filter { modifiers.contains($0.0) }.map(\.1)
        let keyName: String = switch key {
        case "up": "Up Arrow"
        case "down": "Down Arrow"
        case "left": "Left Arrow"
        case "right": "Right Arrow"
        case "return": "Return"
        case "tab": "Tab"
        case "space": "Space"
        case "pageUp": "Page Up"
        case "pageDown": "Page Down"
        case "home": "Home"
        case "end": "End"
        case ",": "Comma"
        case ".": "Period"
        case "/": "Slash"
        default: keyGlyph
        }
        return (names + [keyName]).joined(separator: " ")
    }
}

public enum ShortcutGroup: String, CaseIterable, Sendable, Identifiable {
    case general
    case chat
    case bots
    case view

    public var id: Self { self }
    public var title: String {
        switch self {
        case .general: "General"
        case .chat: "Chat"
        case .bots: "Bots"
        case .view: "View"
        }
    }
}

public enum ShortcutAction: String, CaseIterable, Sendable, Identifiable, Codable {
    case newBot
    case search
    case searchAlternate
    case settings
    case shortcuts
    case focusComposer
    case findInChat
    case previousBot
    case nextBot
    case compactSidebar
    case details
    case connectApps

    public var id: Self { self }

    public var group: ShortcutGroup {
        switch self {
        case .newBot, .search, .searchAlternate, .settings, .shortcuts: .general
        case .focusComposer, .findInChat: .chat
        case .previousBot, .nextBot: .bots
        case .compactSidebar, .details, .connectApps: .view
        }
    }

    public var title: String {
        switch self {
        case .newBot: "New Bot"
        case .search: "Search"
        case .searchAlternate: "Search in All Chats"
        case .settings: "Settings"
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

    public var defaultChord: KeyChord {
        switch self {
        case .newBot: KeyChord(key: "n", modifiers: .command)
        case .search: KeyChord(key: "k", modifiers: .command)
        case .searchAlternate: KeyChord(key: "f", modifiers: [.command, .shift])
        case .settings: KeyChord(key: ",", modifiers: .command)
        case .shortcuts: KeyChord(key: "/", modifiers: .command)
        case .focusComposer: KeyChord(key: "l", modifiers: .command)
        case .findInChat: KeyChord(key: "f", modifiers: .command)
        case .previousBot: KeyChord(key: "up", modifiers: .option)
        case .nextBot: KeyChord(key: "down", modifiers: .option)
        case .compactSidebar: KeyChord(key: "b", modifiers: .command)
        case .details: KeyChord(key: "i", modifiers: [.command, .shift])
        case .connectApps: KeyChord(key: "m", modifiers: [.command, .shift])
        }
    }
}

public enum ChordRefusal: Sendable, Equatable {
    case needsModifier
    case systemReserved(String)
}

public enum ChordCheck: Sendable, Equatable {
    case ok
    case warning(String)
    case refused(ChordRefusal)
}

public enum ChordOccupant: Sendable, Equatable {
    case action(ShortcutAction)
    case goToBot

    public var title: String {
        switch self {
        case .action(let action): action.title
        case .goToBot: "Go to Bot"
        }
    }
}

public enum ChordPolicy {
    private static func chord(_ key: String, _ modifiers: ChordModifiers) -> KeyChord { KeyChord(key: key, modifiers: modifiers) }

    static let reserved: [KeyChord: String] = [
        chord("q", .command): "Quit",
        chord("h", .command): "Hide Pal",
        chord("h", [.command, .option]): "Hide Others",
        chord("space", .command): "Spotlight",
        chord("space", [.command, .option]): "Finder search",
        chord("space", .control): "Input source switcher",
        chord("tab", .command): "App switcher",
        chord("tab", [.command, .shift]): "App switcher",
        chord("`", .command): "Window switcher",
        chord("q", [.command, .control]): "Lock screen",
        chord("f", [.command, .control]): "Full screen",
        chord("3", [.command, .shift]): "Screenshot",
        chord("4", [.command, .shift]): "Screenshot",
        chord("5", [.command, .shift]): "Screenshot",
    ]

    static let overridable: [KeyChord: String] = [
        chord("w", .command): "Close Window",
        chord("m", .command): "Minimize",
        chord("c", .command): "Copy",
        chord("v", .command): "Paste",
        chord("x", .command): "Cut",
        chord("a", .command): "Select All",
        chord("z", .command): "Undo",
        chord("z", [.command, .shift]): "Redo",
    ]

    public static func check(_ candidate: KeyChord) -> ChordCheck {
        let strong: ChordModifiers = [.command, .control, .option]
        if candidate.isFunctionKey { return .ok }
        guard !candidate.modifiers.isDisjoint(with: strong) else { return .refused(.needsModifier) }
        if candidate.isPrintable, candidate.modifiers.isDisjoint(with: [.command, .control]) {
            return .refused(.needsModifier)
        }
        if let name = reserved[candidate] { return .refused(.systemReserved(name)) }
        if let name = overridable[candidate] { return .warning(name) }
        return .ok
    }
}

public struct ShortcutBindings: Sendable, Equatable {
    public enum Override: Codable, Sendable, Equatable {
        case chord(KeyChord)
        case cleared
    }

    public private(set) var overrides: [ShortcutAction: Override]

    public init(overrides: [ShortcutAction: Override] = [:]) {
        self.overrides = overrides.filter { $0.value != .chord($0.key.defaultChord) }
    }

    public func chord(for action: ShortcutAction) -> KeyChord? {
        switch overrides[action] {
        case .chord(let chord)?: chord
        case .cleared?: nil
        case nil: action.defaultChord
        }
    }

    public func isDefault(_ action: ShortcutAction) -> Bool { overrides[action] == nil }
    public var hasCustomizations: Bool { !overrides.isEmpty }

    public func occupant(of candidate: KeyChord, excluding action: ShortcutAction) -> ChordOccupant? {
        if candidate.modifiers == .command, let digit = Int(candidate.key), (1...9).contains(digit) { return .goToBot }
        return ShortcutAction.allCases.first { $0 != action && chord(for: $0) == candidate }.map(ChordOccupant.action)
    }

    public mutating func assign(_ candidate: KeyChord, to action: ShortcutAction) {
        if let other = ShortcutAction.allCases.first(where: { $0 != action && chord(for: $0) == candidate }) {
            set(.cleared, for: other)
        }
        set(.chord(candidate), for: action)
    }

    public mutating func clear(_ action: ShortcutAction) { set(.cleared, for: action) }
    public mutating func reset(_ action: ShortcutAction) { overrides[action] = nil }
    public mutating func resetAll() { overrides = [:] }

    private mutating func set(_ value: Override, for action: ShortcutAction) {
        overrides[action] = value == .chord(action.defaultChord) ? nil : value
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }))
    }

    public init(decoding data: Data?) {
        guard let data, let raw = try? JSONDecoder().decode([String: Override].self, from: data) else {
            self.init()
            return
        }
        var parsed: [ShortcutAction: Override] = [:]
        for (name, value) in raw {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            if case .chord(let chord) = value, case .refused = ChordPolicy.check(chord) { continue }
            parsed[action] = value
        }
        self.init(overrides: Self.dropDuplicates(parsed))
    }

    private static func dropDuplicates(_ parsed: [ShortcutAction: Override]) -> [ShortcutAction: Override] {
        var result = parsed
        var claimed = Set<KeyChord>()
        for action in ShortcutAction.allCases {
            guard case .chord(let chord)? = result[action] else { continue }
            if claimed.insert(chord).inserted { continue }
            result[action] = .cleared
        }
        for action in ShortcutAction.allCases where result[action] == nil {
            if !claimed.insert(action.defaultChord).inserted { result[action] = .cleared }
        }
        return result
    }
}
