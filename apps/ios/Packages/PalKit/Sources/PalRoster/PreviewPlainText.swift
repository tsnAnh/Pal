import Foundation

enum PreviewPlainText {
    private static var link: Regex<(Substring, Substring)> { /!?\[([^\]\n]*)\](?:\([^)\n]*\)?)?/ }
    private static var cutLink: Regex<(Substring, Substring)> { /!?\[([^\]\n]*)$/.anchorsMatchLineEndings() }
    private static var blockMarker: Regex<Substring> { /^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+|\d{1,3}[.)]\s+)/.anchorsMatchLineEndings() }
    private static var pairedMarker: Regex<Substring> { /\*\*|__|~~|`+/ }
    private static var runOfSpaces: Regex<Substring> { /[ \t]{2,}/ }

    static func strip(_ text: String) -> String {
        let unlinked = text
            .replacing(link) { String($0.output.1) }
            .replacing(cutLink) { String($0.output.1) }
            .replacing(blockMarker, with: "")
            .replacing(pairedMarker, with: "")
        return dropEmphasis("_", in: dropEmphasis("*", in: unlinked))
            .replacing(runOfSpaces, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dropEmphasis(_ marker: Character, in text: String) -> String {
        let characters = Array(text)
        let at = { (index: Int) -> Character? in characters.indices.contains(index) ? characters[index] : nil }
        let isWord = { (index: Int) in at(index).map { $0.isLetter || $0.isNumber || $0 == marker } ?? false }
        let isInk = { (index: Int) in at(index).map { !$0.isWhitespace && $0 != marker } ?? false }
        let kept = characters.indices.filter { index in
            guard characters[index] == marker else { return true }
            let opens = !isWord(index - 1) && isInk(index + 1)
            let closes = isInk(index - 1) && !isWord(index + 1)
            return !(opens || closes)
        }
        return String(kept.map { characters[$0] })
    }
}
