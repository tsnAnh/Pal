import Foundation

public struct BotIdentity: Sendable, Equatable {
    public static let maximumSlugLength = 64
    public static let maximumDisplayNameLength = 64
    static let reserved: Set<String> = ["hermes", "default", "test", "tmp", "root", "sudo"]

    public let displayName: String
    public let slug: String

    public init(entered: String) {
        displayName = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        slug = Self.slug(from: displayName)
    }

    public var isValid: Bool {
        guard let first = slug.unicodeScalars.first, Self.isAlphanumeric(first), !slug.isEmpty,
              slug.count <= Self.maximumSlugLength, !Self.reserved.contains(slug)
        else { return false }
        return slug.unicodeScalars.allSatisfy { Self.isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    public static func slug(from value: String) -> String {
        var folded = ""
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard isLetterOrNumber(scalar) else {
                folded.unicodeScalars.append(scalar)
                continue
            }
            let base = asciiBase(of: scalar)
            folded += base ?? "-u\(String(scalar.value, radix: 16))-"
        }
        return capped(sanitize(collapseDashes(folded)))
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }

    private static func asciiBase(of scalar: Unicode.Scalar) -> String? {
        var stripped = ""
        for part in String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(part) {
            stripped.unicodeScalars.append(part)
        }
        guard !stripped.isEmpty, stripped.unicodeScalars.allSatisfy({
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57)
        }) else { return nil }
        return stripped
    }

    private static func collapseDashes(_ value: String) -> String {
        var result = ""
        var previousDash = false
        for character in value {
            if character == "-" {
                if !previousDash { result.append(character) }
                previousDash = true
            } else {
                result.append(character)
                previousDash = false
            }
        }
        return result
    }

    private static func sanitize(_ value: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in value.lowercased().unicodeScalars {
            if isAlphanumeric(scalar) || scalar == "_" || scalar == "-" {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private static func capped(_ slug: String) -> String {
        guard slug.count > maximumSlugLength else { return slug }
        let characters = Array(slug)
        let cut = String(characters[0..<maximumSlugLength])
        let boundary = characters[maximumSlugLength] == "-" ? maximumSlugLength : (cut.lastIndex(of: "-").map { cut.distance(from: cut.startIndex, to: $0) } ?? -1)
        var trimmed = boundary > 0 ? String(characters[0..<boundary]) : cut
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }
}
