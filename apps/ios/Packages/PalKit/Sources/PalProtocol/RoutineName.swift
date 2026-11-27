import Foundation

public enum RoutineName {
    public static var untitled: String { String(localized: "Untitled routine") }

    public static func readable(_ stored: String?, jobID: String = "") -> String? {
        let name = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.caseInsensitiveCompare(jobID) != .orderedSame else { return nil }
        let isSlug = !name.contains(where: \.isWhitespace)
        var spaced = name.replacing(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, with: " ")
            .replacing("_", with: " ")
        if isSlug { spaced = spaced.replacing("-", with: " ") }
        var words = spaced.split(whereSeparator: \.isWhitespace)
        if isSlug { words.removeAll(where: isHexID) }
        var sentence = words.joined(separator: " ")
        guard !words.allSatisfy(isHexID), sentence.contains(where: \.isLetter) else { return nil }
        if isSlug, words.count > 1, !sentence.contains(where: \.isLowercase) { sentence = sentence.lowercased() }
        let isCasedWord = sentence.prefix { !$0.isWhitespace }.dropFirst().contains(where: \.isUppercase)
        return isCasedWord ? sentence : sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    private static func isHexID(_ word: Substring) -> Bool {
        word.count >= 8 && word.allSatisfy(\.isHexDigit) && word.contains(where: \.isNumber)
    }
}
