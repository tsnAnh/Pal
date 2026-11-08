import Foundation

public struct LastReply: Sendable, Equatable {
    public let text: String
    public let botIsWorkingOnMore: Bool

    public init(text: String, botIsWorkingOnMore: Bool) {
        self.text = text
        self.botIsWorkingOnMore = botIsWorkingOnMore
    }
}

extension Transcript {
    public var lastReply: LastReply? {
        var collected: [String] = []
        for item in items.reversed() {
            if item.isUser {
                if collected.isEmpty { continue } else { break }
            }
            if let reply = item.finishedReply { collected.append(reply) }
        }
        guard !collected.isEmpty else { return nil }
        return LastReply(text: collected.reversed().joined(separator: "\n\n"), botIsWorkingOnMore: isRunning)
    }
}

public struct SpokenExcerpt: Sendable, Equatable {
    public static let defaultLimit = 400

    public let text: String
    public let isTruncated: Bool

    public init(_ full: String, limit: Int = Self.defaultLimit) {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            text = trimmed
            isTruncated = false
            return
        }
        let head = trimmed.prefix(limit)
        let floor = limit / 2
        let sentenceEnd = head.lastIndex { ".!?\n".contains($0) }
        let wordEnd = head.lastIndex { $0.isWhitespace }
        let cut: Substring
        if let end = sentenceEnd, head.distance(from: head.startIndex, to: end) >= floor {
            cut = head[...end]
        } else if let end = wordEnd, head.distance(from: head.startIndex, to: end) >= floor {
            cut = head[..<end]
        } else {
            cut = head
        }
        text = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        isTruncated = true
    }
}
