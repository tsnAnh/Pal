public enum ComposerPlatform: Sendable {
    case mac
    case padWithKeyboard
    case touch
}

public struct ComposerModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ComposerModifiers(rawValue: 1 << 0)
    public static let option = ComposerModifiers(rawValue: 1 << 1)
    public static let command = ComposerModifiers(rawValue: 1 << 2)
    public static let control = ComposerModifiers(rawValue: 1 << 3)
}

public enum ComposerKeyAction: Equatable, Sendable {
    case send
    case newline
    case acceptCompletion
    case ignore
}

public enum ComposerKeys {
    public static func returnAction(
        modifiers: ComposerModifiers,
        isComposing: Bool,
        platform: ComposerPlatform,
        hasCompletionSelection: Bool
    ) -> ComposerKeyAction {
        guard platform != .touch, !isComposing else { return .ignore }
        if !modifiers.isDisjoint(with: [.shift, .option]) { return .newline }
        if modifiers.contains(.control) { return .ignore }
        if modifiers.contains(.command) { return .send }
        return hasCompletionSelection ? .acceptCompletion : .send
    }
}
