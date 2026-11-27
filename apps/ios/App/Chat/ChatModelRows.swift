import Foundation
import PalChat
import PalDesign
import PalDiagnostics
import PalProtocol

enum ChatNotice: Equatable {
    case botMessage(senderName: String, body: String)
}

enum ChatRowGap: Equatable {
    case none
    case sameSender
    case senderSwitch
}

extension ChatModel {
    static func isEmpty(_ kind: ChatRow.Kind, images: [ImageReference], files: [FileReference]) -> Bool {
        if case .assistant(let parsed) = kind, parsed.source.isEmpty, images.isEmpty, files.isEmpty { return true }
        return false
    }

    static func gap(for row: ChatRow, after previous: ChatRow?) -> ChatRowGap {
        guard previous != nil, row.separator == nil, !row.showsUnreadDivider else { return .none }
        guard let sender = row.sender, sender == previous?.sender else { return .senderSwitch }
        return .sameSender
    }

    static func dependsOnOutbox(_ item: TranscriptItem) -> Bool {
        if case .user(_, .sending) = item.content { return true }
        return false
    }

    static func flagDuplicateIDs(in rows: [ChatRow]) {
        var seen: Set<String> = []
        let duplicates = rows.count { !seen.insert($0.id).inserted }
        guard duplicates > 0 else { return }
        PalPerf.event("chat.rows.duplicate", count: duplicates)
        assertionFailure("chat rows share an id")
    }
}
