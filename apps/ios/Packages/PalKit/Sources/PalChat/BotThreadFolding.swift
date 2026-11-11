import Foundation
import PalProtocol

public enum BotThreadFolding {
    public static func fold(_ items: [TranscriptItem], links: [BotThreadLink]) -> [TranscriptItem] {
        guard !links.isEmpty else { return items }
        let present = Set(items.compactMap(\.uid))
        var owner: [String: BotThreadLink] = [:]
        for link in links {
            for uid in link.coveredUIDs + [link.anchorUID] where owner[uid] == nil { owner[uid] = link }
        }
        var placed: Set<String> = []
        var folded: [TranscriptItem] = []
        folded.reserveCapacity(items.count)
        for item in items {
            guard let uid = item.uid, let link = owner[uid] else {
                folded.append(item)
                continue
            }
            let anchorPresent = present.contains(link.anchorUID)
            guard uid == link.anchorUID || !anchorPresent else { continue }
            guard placed.insert(link.anchorUID).inserted else { continue }
            folded.append(TranscriptItem(
                id: "bot-thread:\(link.anchorUID)",
                content: .botThread(link),
                timestamp: item.timestamp,
                uid: link.anchorUID
            ))
        }
        return folded
    }
}
