import PalChat
import SwiftUI

@MainActor
final class ChatRowHeights {
    static let batchSize = 4

    private var cache = ChatRowHeightCache()
    private var recorded: Set<String> = []
    private var unmeasurable: Set<String> = []
    private var lastRows: [String: ChatRow] = [:]

    func rowsChanged(_ live: Set<String>) {
        lastRows = lastRows.filter { live.contains($0.key) }
        for id in recorded.subtracting(live) { cache.invalidate(id) }
        recorded.formIntersection(live)
        unmeasurable.formIntersection(live)
    }

    func laidOut(_ id: String, height: Double, width: Double) {
        cache.record(id, height: height, width: width)
        recorded.insert(id)
    }

    func minHeight(for row: ChatRow, width: Double?) -> CGFloat? {
        if lastRows[row.id] != row {
            forget(row.id)
            lastRows[row.id] = row
        }
        guard !row.isStreaming, let width, let height = cache.height(for: row.id, width: width) else { return nil }
        return CGFloat(height)
    }

    func batch(of rows: [ChatRow], width: Double) -> [ChatRow] {
        var candidates: [String: ChatRow] = [:]
        var order: [String] = []
        for row in rows where !row.isStreaming {
            if let known = lastRows[row.id], known != row { forget(row.id) }
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
        lastRows[row.id] = row
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
        lastRows[id] = nil
    }
}
