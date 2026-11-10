import Foundation

public enum TranscriptVisibility {
    static let silentReply = "[SILENT]"
    static let cronjobTurnPrefix = "[Cronjob \""

    public static func isHidden(_ item: TranscriptItem, botChat: Bool = true) -> Bool {
        switch item.content {
        case .assistant(let text, _, _):
            text.trimmingCharacters(in: .whitespacesAndNewlines) == silentReply
        case .user(let text, _):
            item.inbound == .processCompletion
                || (botChat && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(cronjobTurnPrefix))
        default:
            false
        }
    }

    public static func visible(_ items: [TranscriptItem], botChat: Bool = true) -> [TranscriptItem] {
        items.filter { !isHidden($0, botChat: botChat) }
    }
}
