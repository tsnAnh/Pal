import Foundation

public struct BotSender: Sendable, Hashable {
    public var name: String
    public var handle: String

    public init(name: String, handle: String) {
        self.name = name
        self.handle = handle
    }
}

public enum InboundKind: Sendable, Hashable {
    case person
    case botMessage(BotSender, body: String)
    case systemNotification
    case processCompletion

    public var isPerson: Bool { self == .person }
}

extension InboundKind {
    private static let processCompletionKinds: Set<String> = ["process_complete", "async_delegation_complete"]
    private static let internalNotificationKind = "internal_notification"
    private static let backgroundProcessPrefix = "[IMPORTANT: Background process"
    private static let backgroundBatch = try! NSRegularExpression(
        pattern: "\\A\\[IMPORTANT: (\\d+) background process results arrived "
    )
    private static let botStamp = try! NSRegularExpression(
        pattern: "\\AMessage from 🤖 (.+?) \\(@([A-Za-z0-9_-]+)\\): ?(.*)\\z",
        options: [.dotMatchesLineSeparators]
    )

    public static func classify(text: String, displayKind: String?) -> InboundKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayKind, processCompletionKinds.contains(displayKind) { return .processCompletion }
        if trimmed.hasPrefix(backgroundProcessPrefix) || batchCount(in: trimmed) != nil { return .processCompletion }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = botStamp.firstMatch(in: trimmed, range: range),
           let name = Range(match.range(at: 1), in: trimmed),
           let handle = Range(match.range(at: 2), in: trimmed),
           let body = Range(match.range(at: 3), in: trimmed)
        {
            return .botMessage(BotSender(name: String(trimmed[name]), handle: String(trimmed[handle])), body: String(trimmed[body]))
        }
        if displayKind == internalNotificationKind { return .systemNotification }
        return .person
    }

    public static func backgroundTaskCount(in text: String) -> Int {
        batchCount(in: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    private static func batchCount(in trimmed: String) -> Int? {
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = backgroundBatch.firstMatch(in: trimmed, range: range),
              let digits = Range(match.range(at: 1), in: trimmed),
              let count = Int(trimmed[digits])
        else { return nil }
        return max(count, 1)
    }
}
