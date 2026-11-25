import Foundation

public enum TypeToFocus {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
    }

    public static func insertion(
        characters: String, modifiers: Modifiers, textInputFocused: Bool, blocked: Bool
    ) -> String? {
        guard !textInputFocused, !blocked, modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        guard !characters.isEmpty, !characters.allSatisfy(\.isWhitespace), !characters.hasPrefix(uikitKeyNamePrefix) else { return nil }
        return characters.unicodeScalars.contains(where: isNonTyping) ? nil : characters
    }

    private static let uikitKeyNamePrefix = "UIKeyInput"

    private static func isNonTyping(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || (0xF700...0xF8FF).contains(scalar.value)
    }
}
