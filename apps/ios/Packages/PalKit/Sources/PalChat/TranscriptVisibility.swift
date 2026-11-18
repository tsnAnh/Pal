import Foundation

public enum TranscriptVisibility {
    static let silentReply = "[SILENT]"
    static let cronjobTurnPrefix = "[Cronjob \""

    public static func isHidden(_ item: TranscriptItem, botChat: Bool = true) -> Bool {
        switch item.content {
        case .assistant(let text, _, _):
            text.trimmingCharacters(in: .whitespacesAndNewlines) == silentReply
        case .user(let text, _):
            isHiddenUserTurn(text, inbound: item.inbound, botChat: botChat)
        default:
            false
        }
    }

    private static func isHiddenUserTurn(_ text: String, inbound: InboundKind, botChat: Bool) -> Bool {
        switch inbound {
        case .internalNotice: true
        case .person: botChat && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(cronjobTurnPrefix)
        case .botMessage, .routineOutput: false
        }
    }

    public static func visible(_ items: [TranscriptItem], botChat: Bool = true) -> [TranscriptItem] {
        items.filter { !isHidden($0, botChat: botChat) }
    }
}
