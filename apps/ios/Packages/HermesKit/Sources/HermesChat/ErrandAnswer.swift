import Foundation
import HermesProtocol

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

public enum ApprovalDecision: Sendable, Equatable {
    case approve
    case deny

    public func choice(in prompt: PendingPrompt) -> String? {
        let wanted = self == .approve ? "once" : "deny"
        guard !prompt.choices.isEmpty else { return wanted }
        return prompt.choices.first { $0 == wanted }
    }
}

extension PendingPrompt {
    public static let spokenCommandLimit = 140

    public func canonicalAnswer(for spoken: String) -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return choices.first { $0.compare(bare, options: options) == .orderedSame } ?? trimmed
    }

    public var shortCommand: String? {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let flat = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > Self.spokenCommandLimit else { return flat }
        return flat.prefix(Self.spokenCommandLimit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
