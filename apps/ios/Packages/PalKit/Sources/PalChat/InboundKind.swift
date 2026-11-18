import Foundation
import PalProtocol

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
    case routineOutput(jobName: String, body: String, failed: Bool)

    public var isPerson: Bool { self == .person }
}

extension InboundKind {
    private static let processCompletionKinds: Set<String> = ["process_complete", "async_delegation_complete"]
    private static let personKinds: Set<String> = ["steer", "skill_invocation"]
    private static let processCompletionPrefixes = ["[IMPORTANT: Background process", "[ASYNC DELEGATION "]
    private static let backgroundBatch = try! NSRegularExpression(
        pattern: "\\A\\[IMPORTANT: (\\d+) background process results arrived "
    )
    private static let cleanExit = "Background process "
    private static let cleanExitSuffix = " completed normally (exit code 0)"
    private static let routineKinds: Set<String> = ["routine_output", "cron_output"]
    private static let routineJobKeys = ["job_name", "name", "job"]
    private static let routineFailedStatuses: Set<String> = ["failed", "failure", "error"]
    private static let routineOpening = "[Cronjob \""
    private static let routineJobEnd = "\" output — "
    private static let routineHeaderEnd = "]\n\n"
    private static let botStamp = try! NSRegularExpression(
        pattern: "\\AMessage from 🤖 (.+?) \\(@([A-Za-z0-9_-]+)\\): ?(.*)\\z",
        options: [.dotMatchesLineSeparators]
    )

    public static func classify(text: String, of row: some InboundRowWire) -> InboundKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayKind = row.displayKind
        if let displayKind, processCompletionKinds.contains(displayKind) { return .processCompletion }
        if processCompletionPrefixes.contains(where: trimmed.hasPrefix) || batchCount(in: trimmed) != nil {
            return .processCompletion
        }
        if let routine = routineOutput(trimmed, displayKind: displayKind, metadata: row.displayMetadata) { return routine }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = botStamp.firstMatch(in: trimmed, range: range),
           let name = Range(match.range(at: 1), in: trimmed),
           let handle = Range(match.range(at: 2), in: trimmed),
           let body = Range(match.range(at: 3), in: trimmed)
        {
            return .botMessage(BotSender(name: String(trimmed[name]), handle: String(trimmed[handle])), body: String(trimmed[body]))
        }
        if let displayKind, !personKinds.contains(displayKind) { return .systemNotification }
        return .person
    }

    public static func splitFirstSentence(of body: String) -> (lead: String, rest: String) {
        let lineEnd = body.firstIndex(where: \.isNewline) ?? body.endIndex
        var index = body.startIndex
        while index < lineEnd {
            let next = body.index(after: index)
            if ".!?".contains(body[index]), next == body.endIndex || body[next].isWhitespace {
                return (String(body[..<next]), String(body[next...].drop(while: \.isWhitespace)))
            }
            index = next
        }
        return (String(body[..<lineEnd]), String(body[lineEnd...].drop(while: \.isWhitespace)))
    }

    public static func backgroundTaskCount(in text: String) -> Int {
        batchCount(in: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    public static func isSuccessfulCompletion(_ text: String) -> Bool {
        let clean = text.components(separatedBy: "[IMPORTANT: ").dropFirst().filter { notice in
            let header = notice.prefix { !$0.isNewline }
            return header.hasPrefix(cleanExit) && header.contains(cleanExitSuffix)
        }
        return clean.count >= backgroundTaskCount(in: text)
    }

    private static func routineWrapper(in trimmed: String) -> (job: String, body: String)? {
        guard trimmed.hasPrefix(routineOpening),
              let jobEnd = trimmed.range(of: routineJobEnd),
              let headerEnd = trimmed.range(of: routineHeaderEnd, range: jobEnd.upperBound..<trimmed.endIndex)
        else { return nil }
        let job = trimmed[trimmed.index(trimmed.startIndex, offsetBy: routineOpening.count)..<jobEnd.lowerBound]
        guard !job.contains(where: \.isNewline), !trimmed[jobEnd.upperBound..<headerEnd.lowerBound].contains(where: \.isNewline) else { return nil }
        return (String(job), String(trimmed[headerEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func routineOutput(_ trimmed: String, displayKind: String?, metadata: JSONValue?) -> InboundKind? {
        if let displayKind, personKinds.contains(displayKind) { return nil }
        let wrapped = routineWrapper(in: trimmed)
        guard wrapped != nil || displayKind.map(routineKinds.contains) == true else { return nil }
        let body = wrapped?.body ?? trimmed
        guard !body.isEmpty else { return nil }
        let sentJob = routineJobKeys.lazy.compactMap { metadata?[$0]?.stringValue }.first { !$0.isEmpty }
        return .routineOutput(jobName: sentJob ?? wrapped?.job ?? "", body: body, failed: runFailed(metadata))
    }

    private static func runFailed(_ metadata: JSONValue?) -> Bool {
        if metadata?["failed"]?.boolValue == true || metadata?["ok"]?.boolValue == false { return true }
        return metadata?["status"]?.stringValue.map { routineFailedStatuses.contains($0.lowercased()) } ?? false
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
