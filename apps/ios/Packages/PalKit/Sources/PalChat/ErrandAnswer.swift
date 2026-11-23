import Foundation
import PalProtocol

public struct AnswerMark: Sendable, Equatable {
    public let promptID: String
    public let userItemsAtAnswer: Int
    public let repliesBefore: Int
}

extension Transcript {
    public func answerMark(for prompt: PendingPrompt) -> AnswerMark {
        let ordinal = userItemCount
        let before = turn(afterUserOrdinal: ordinal).prefix { !$0.isUser }.count { $0.finishedReply != nil }
        return AnswerMark(promptID: prompt.promptID, userItemsAtAnswer: ordinal, repliesBefore: before)
    }

    public func errandOutcome(for mark: AnswerMark) -> ErrandOutcome? {
        guard !pendingPrompts.contains(where: { $0.promptID == mark.promptID }) else { return nil }
        let tail = turn(afterUserOrdinal: mark.userItemsAtAnswer)
        let output = tail.prefix { !$0.isUser }
        if let prompt = output.lazy.compactMap(\.prompt).first { return .needsInput(prompt) }
        guard output.count < tail.count || !isRunning else { return nil }
        let replies = output.compactMap(\.finishedReply).dropFirst(mark.repliesBefore)
        if !replies.isEmpty { return .replied(replies.joined(separator: "\n\n")) }
        if let lastError, !lastError.isEmpty { return .failed(.turnFailed(message: lastError)) }
        return .finishedQuietly
    }

    private func turn(afterUserOrdinal ordinal: Int) -> ArraySlice<TranscriptItem> {
        guard ordinal > 0 else { return items[...] }
        var seen = 0
        for (index, item) in items.enumerated() where item.isUser {
            seen += 1
            if seen == ordinal { return items[(index + 1)...] }
        }
        return []
    }
}

extension PendingPrompt {
    public func canonicalAnswer(for spoken: String) -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return choices.first { $0.compare(bare, options: options) == .orderedSame } ?? trimmed
    }
}
