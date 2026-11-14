import SwiftUI

public enum InlineTextComposer {
    public static func compose(_ text: AttributedString, linkIcon: (URL) -> Text) -> Text {
        var result = Text("")
        for run in text.runs {
            let slice = AttributedString(text[run.range])
            if let link = run.link {
                result = Text("\(result)\(linkIcon(link))\(Text(" "))\(Text(slice).underline())")
            } else {
                result = Text("\(result)\(Text(slice))")
            }
        }
        return result
    }

    public static func highlight(_ text: AttributedString, query: String, fill: Color, ink: Color?) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var result = text
        let plain = String(text.characters)
        var searchRange = plain.startIndex..<plain.endIndex
        while let found = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let lower = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: found.lowerBound))
            let upper = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: found.upperBound))
            result[lower..<upper].backgroundColor = fill
            if let ink { result[lower..<upper].foregroundColor = ink }
            searchRange = found.upperBound..<plain.endIndex
        }
        return result
    }
}
