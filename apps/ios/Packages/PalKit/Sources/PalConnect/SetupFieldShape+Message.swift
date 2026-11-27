import Foundation

extension SetupFieldShape {
    private static func spelledOut(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en")
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    public func message(label: String) -> String? {
        let name = label.prefix(1).lowercased() + label.dropFirst()
        switch self {
        case .empty: return nil
        case .valid: return String(localized: "Looks right")
        case .hasSpaces: return String(localized: "The \(name) can't contain spaces. Paste it again without them.")
        case .wrongStart(let prefixes):
            return String(localized: "That is not a \(name). It starts with \(prefixes.joined(separator: String(localized: " or "))). Copy it again.")
        case .wrongEnd(let suffix): return String(localized: "That is not a \(name). It ends with \(suffix). Copy it again.")
        case .wrongParts(let count):
            let spelled = Self.spelledOut(count)
            return String(localized: "That is not a \(name). A \(name) is \(spelled) parts joined by dots. Copy it again.")
        case .wrongDigits(let count):
            return String(localized: "That is not a user id. It has \(count.lowerBound) to \(count.upperBound) digits. Copy it again.")
        }
    }
}
