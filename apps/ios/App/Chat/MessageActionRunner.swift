import PalChat
import SwiftUI

extension MessageAction {
    @MainActor
    func title(speakingRowID: String?, rowID: String) -> String {
        switch self {
        case .reply: String(localized: "Reply")
        case .markUnread: String(localized: "Mark as Unread")
        case .markRead: String(localized: "Mark as Read")
        case .copy: String(localized: "Copy")
        case .selectText: String(localized: "Select Text")
        case .share: String(localized: "Share…")
        case .speak: speakingRowID == rowID ? String(localized: "Stop Speaking") : String(localized: "Speak")
        case .retry: String(localized: "Retry")
        case .copyTable: String(localized: "Copy table")
        }
    }

    var symbol: String {
        switch self {
        case .reply: "arrow.uturn.left"
        case .markUnread: "circle.fill"
        case .markRead: "checkmark.circle"
        case .copy: "doc.on.doc"
        case .selectText: "text.cursor"
        case .share: "square.and.arrow.up"
        case .speak: "speaker.wave.2"
        case .retry: "arrow.clockwise"
        case .copyTable: "tablecells"
        }
    }

    var identifier: String {
        switch self {
        case .reply: "contextReply"
        case .markUnread: "contextMarkUnread"
        case .markRead: "contextMarkRead"
        case .copy: "contextCopy"
        case .selectText: "contextSelectText"
        case .share: "contextShare"
        case .speak: "contextSpeak"
        case .retry: "contextRetry"
        case .copyTable: "contextCopyTable"
        }
    }
}

enum TableCopyFormat {
    case markdown
    case tsv
}

@MainActor
enum MessageActionRunner {
    static func perform(_ action: MessageAction, on actions: MessageActions) {
        switch action {
        case .reply: actions.reply()
        case .markUnread, .markRead: actions.toggleUnread()
        case .copy: Pasteboard.string = actions.text
        case .speak: MessageSpeaker.shared.toggle(rowID: actions.rowID, text: actions.text)
        case .retry: actions.retry?()
        case .selectText, .share, .copyTable: break
        }
    }

    static func copyTables(_ actions: MessageActions, as format: TableCopyFormat) {
        let tables = actions.tables()
        guard !tables.isEmpty else { return }
        let rendered = tables.map { format == .markdown ? $0.markdown : $0.tsv }
        Pasteboard.string = rendered.joined(separator: "\n\n")
    }
}
