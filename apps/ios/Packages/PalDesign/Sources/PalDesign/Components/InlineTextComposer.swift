import SwiftUI

public enum InlineTextComposer {
    public static func compose(_ text: AttributedString, linkIcon: (URL) -> Text) -> Text {
        var pieces: [Text] = []
        var pending = AttributedString()
        for (link, range) in text.runs[\.link] {
            var slice = AttributedString(text[range])
            if let link {
                pieces.append(Text(pending))
                pieces.append(linkIcon(link))
                slice.underlineStyle = .single
                pending = AttributedString(" ") + slice
            } else {
                pending += slice
            }
        }
        pieces.append(Text(pending))
        return joined(pieces[...])
    }

    private static func joined(_ pieces: ArraySlice<Text>) -> Text {
        switch pieces.count {
        case 0: return Text("")
        case 1: return pieces[pieces.startIndex]
        default:
            let middle = pieces.startIndex + pieces.count / 2
            return Text("\(joined(pieces[..<middle]))\(joined(pieces[middle...]))")
        }
    }

    public static func highlight(_ text: AttributedString, query: String, fill: Color, ink: Color?) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var result = text
        let plain = String(text.characters)
        var searchRange = plain.startIndex..<plain.endIndex
        var plainCursor = plain.startIndex
        var cursor = result.startIndex
        while let found = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let lower = result.characters.index(cursor, offsetBy: plain.distance(from: plainCursor, to: found.lowerBound))
            let upper = result.characters.index(lower, offsetBy: plain.distance(from: found.lowerBound, to: found.upperBound))
            result[lower..<upper].backgroundColor = fill
            if let ink { result[lower..<upper].foregroundColor = ink }
            plainCursor = found.upperBound
            cursor = upper
            searchRange = found.upperBound..<plain.endIndex
        }
        return result
    }
}
