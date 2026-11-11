import Foundation

public struct SpeechChunker: Sendable {
    public var maximumLength: Int
    private var consumedLength = 0

    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    public init(maximumLength: Int = 240) {
        self.maximumLength = max(1, maximumLength)
    }

    public mutating func reset() {
        consumedLength = 0
    }

    public mutating func consume(_ text: String, isFinal: Bool) -> [String] {
        let characters = Array(Self.spokenText(from: text))
        var start = min(consumedLength, characters.count)
        var chunks: [String] = []
        var index = start
        while index < characters.count {
            let character = characters[index]
            let endsHere: Bool
            if character == "\n" {
                endsHere = true
            } else if Self.terminators.contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                endsHere = next.map { $0.isWhitespace } ?? isFinal
            } else {
                endsHere = false
            }
            if endsHere {
                let end = character == "\n" ? index : index + 1
                chunks.append(contentsOf: Self.pieces(String(characters[start..<end]), limit: maximumLength))
                start = index + 1
            }
            index += 1
        }
        if isFinal {
            chunks.append(contentsOf: Self.pieces(String(characters[start...]), limit: maximumLength))
            start = characters.count
        } else {
            while characters.count - start > maximumLength, let cut = Self.lastSpace(in: characters, from: start, limit: maximumLength) {
                chunks.append(contentsOf: Self.pieces(String(characters[start..<cut]), limit: maximumLength))
                start = cut + 1
            }
        }
        consumedLength = start
        return chunks
    }

    public static func spokenText(from markdown: String) -> String {
        MarkdownDocument(parsing: markdown).blocks
            .compactMap { block -> String? in
                switch block.kind {
                case .code, .math, .thematicBreak: nil
                case .paragraph, .heading: String(block.text.characters)
                }
            }
            .joined(separator: "\n")
    }

    private static func pieces(_ raw: String, limit: Int) -> [String] {
        var remaining = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: [String] = []
        while remaining.count > limit {
            let characters = Array(remaining)
            guard let cut = lastSpace(in: characters, from: 0, limit: limit) else { break }
            result.append(String(characters[..<cut]).trimmingCharacters(in: .whitespaces))
            remaining = Substring(String(characters[(cut + 1)...]))
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }

    private static func lastSpace(in characters: [Character], from start: Int, limit: Int) -> Int? {
        let upper = min(characters.count - 1, start + limit)
        guard upper > start else { return nil }
        return (start...upper).reversed().first { characters[$0] == " " }
    }
}
