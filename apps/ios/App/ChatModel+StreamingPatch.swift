import Foundation
import PalChat

struct RebuildCounts: Equatable {
    var full = 0
    var patched = 0
}

struct StreamingRowPatch {
    let sourceID: String
    let row: ChatRow
    let built: ChatModel.BuiltRow
}

extension ChatModel {
    func streamingPatch(from previous: TimelineSnapshot, to next: TimelineSnapshot) -> StreamingRowPatch? {
        guard builtWithBaseline, builtOffline == isOffline, let tail = rows.last,
              let newest = next.rows.last, let oldest = previous.rows.last,
              next.rows.count == previous.rows.count,
              newest.id == oldest.id, newest.rowID == oldest.rowID, newest.entryID == oldest.entryID,
              case .assistant = newest.item.content, case .assistant = oldest.item.content,
              !TranscriptVisibility.isHidden(newest.item)
        else { return nil }
        let sourceID = rowID(for: newest)
        guard tail.id == sourceID, next.rows.dropLast() == previous.rows.dropLast() else { return nil }
        var probe = newest.item
        probe.content = oldest.item.content
        guard probe == oldest.item else { return nil }
        let made = build(newest.item, outbox: nil, generated: generatedImageIDs, reuse: built[sourceID])
        guard let kind = made.kind, !Self.isEmpty(kind, images: made.images, files: made.files) else { return nil }
        var row = ChatRow(id: sourceID, kind: kind, separator: tail.separator, showsUnreadDivider: tail.showsUnreadDivider)
        row.gap = tail.gap
        row.images = made.images
        row.files = made.files
        if case .assistant(_, _, let streaming) = made.item.content { row.isStreaming = streaming }
        row.storedRowID = newest.rowID
        return StreamingRowPatch(sourceID: sourceID, row: row, built: made)
    }
}
