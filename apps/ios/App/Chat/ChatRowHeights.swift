import PalChat
import SwiftUI

@MainActor
final class ChatRowHeights {
    static let batchSize = 4

    private var cache = ChatRowHeightCache()
    private var recorded: Set<String> = []
    private var unmeasurable: Set<String> = []
    private var lastLayouts: [String: ChatRow] = [:]

    func rowsChanged(_ live: Set<String>) {
        lastLayouts = lastLayouts.filter { live.contains($0.key) }
        for id in recorded.subtracting(live) { cache.invalidate(id) }
        recorded.formIntersection(live)
        unmeasurable.formIntersection(live)
    }

    func laidOut(_ id: String, height: Double, width: Double) {
        cache.record(id, height: height, width: width)
        recorded.insert(id)
    }

    func minHeight(for row: ChatRow, width: Double?) -> CGFloat? {
        if lastLayouts[row.id] != row.layoutKey {
            forget(row.id)
            lastLayouts[row.id] = row.layoutKey
        }
        guard !row.isStreaming, let width, let height = cache.height(for: row.id, width: width) else { return nil }
        return CGFloat(height)
    }

    func batch(of rows: [ChatRow], width: Double) -> [ChatRow] {
        var candidates: [String: ChatRow] = [:]
        var order: [String] = []
        for row in rows where !row.isStreaming {
            if let known = lastLayouts[row.id], known != row.layoutKey { forget(row.id) }
            candidates[row.id] = row
            order.append(row.id)
        }
        let picked = cache.unmeasured(in: order, width: width, skipping: unmeasurable, limit: Self.batchSize)
        return picked.compactMap { candidates[$0] }
    }

    func measured(_ row: ChatRow, height: Double, width: Double) {
        guard height > 0 else {
            unmeasurable.insert(row.id)
            return
        }
        laidOut(row.id, height: height, width: width)
        lastLayouts[row.id] = row.layoutKey
    }

    func giveUp(on ids: [String], width: Double) -> Bool {
        let missing = ids.filter { cache.height(for: $0, width: width) == nil }
        unmeasurable.formUnion(missing)
        return !missing.isEmpty
    }

    func widthChanged() {
        unmeasurable.removeAll()
    }

    private func forget(_ id: String) {
        cache.invalidate(id)
        recorded.remove(id)
        unmeasurable.remove(id)
        lastLayouts[id] = nil
    }
}

extension ChatRow {
    var layoutKey: ChatRow {
        guard case .user(let text, let delivery) = kind else { return self }
        if case .failed = delivery { return self }
        return ChatRow(
            id: id, kind: .user(text: text, delivery: .sent), separator: separator, showsUnreadDivider: showsUnreadDivider,
            gap: gap, images: images, files: files, isStreaming: isStreaming, storedRowID: storedRowID
        )
    }
}
