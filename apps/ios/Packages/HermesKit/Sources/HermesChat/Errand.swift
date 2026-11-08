import Foundation
import HermesProtocol

public enum ErrandFailure: Sendable, Equatable {
    case refused(reason: String)
    case turnFailed(message: String)
}

public enum ErrandOutcome: Sendable, Equatable {
    case replied(String)
    case needsInput(PendingPrompt)
    case stillWorking
    case failed(ErrandFailure)
    case finishedQuietly
}

public struct ErrandMark: Sendable, Equatable {
    public let submissionID: String
    public let text: String
    public let userItemsBefore: Int

    public init(submissionID: String, text: String, userItemsBefore: Int) {
        self.submissionID = submissionID
        self.text = text
        self.userItemsBefore = userItemsBefore
    }
}

extension Transcript {
    public var userItemCount: Int {
        items.reduce(0) { count, item in
            if case .user = item.content { count + 1 } else { count }
        }
    }

    public func errandOutcome(for mark: ErrandMark) -> ErrandOutcome? {
        guard let anchor = errandAnchor(for: mark) else { return nil }
        let item = items[anchor]
        if let reason = item.deliveryFailure { return .failed(.refused(reason: reason)) }
        guard case .user(_, .sent) = item.content else { return nil }
        let start = min(turnOutputStart(after: item.id, anchoredAt: anchor), items.count)
        let tail = items[start...]
        let output = tail.prefix { !$0.isUser }
        let turnIsClosed = output.count < tail.count
        if let prompt = output.lazy.compactMap(\.prompt).first { return .needsInput(prompt) }
        guard turnIsClosed || !isRunning else { return nil }
        let replies = output.compactMap(\.finishedReply)
        if !replies.isEmpty { return .replied(replies.joined(separator: "\n\n")) }
        if !output.isEmpty, let lastError, !lastError.isEmpty { return .failed(.turnFailed(message: lastError)) }
        return nil
    }

    private func errandAnchor(for mark: ErrandMark) -> Int? {
        let echoID = Self.echoID(mark.submissionID)
        if let index = items.firstIndex(where: { $0.id == echoID }) { return index }
        var ordinal = 0
        for (index, item) in items.enumerated() {
            guard case .user(let text, _) = item.content else { continue }
            if ordinal >= mark.userItemsBefore, text == mark.text { return index }
            ordinal += 1
        }
        return nil
    }
}

extension TranscriptItem {
    var isUser: Bool {
        if case .user = content { true } else { false }
    }

    var prompt: PendingPrompt? {
        switch content {
        case .clarify(let card), .approval(let card): card.prompt
        default: nil
        }
    }

    var finishedReply: String? {
        guard case .assistant(let text, _, false) = content else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
