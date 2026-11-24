import Foundation

public struct ChatRowHeightCache: Sendable, Equatable {
    private var heights: [String: Double] = [:]
    private var order: [String] = []
    private let capacity: Int
    public private(set) var width: Double?

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { heights.count }

    public mutating func record(_ id: String, height: Double, width newWidth: Double) {
        if let width, abs(width - newWidth) > 0.5 { clear() }
        if width.map({ abs($0 - newWidth) > 0.5 }) ?? true { width = newWidth }
        guard height > 0 else { return }
        forget(id)
        heights[id] = height
        order.append(id)
        evictOverflow()
    }

    public func height(for id: String, width queryWidth: Double) -> Double? {
        guard let width, abs(width - queryWidth) <= 0.5 else { return nil }
        return heights[id]
    }

    public func unmeasured(in ids: [String], width queryWidth: Double, skipping skipped: Set<String> = [], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var found: [String] = []
        for id in ids.reversed() where !skipped.contains(id) && height(for: id, width: queryWidth) == nil {
            found.append(id)
            if found.count == limit { break }
        }
        return found
    }

    public mutating func invalidate(_ id: String) {
        forget(id)
    }

    private mutating func clear() {
        heights.removeAll()
        order.removeAll()
    }

    private mutating func forget(_ id: String) {
        guard heights.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
    }

    private mutating func evictOverflow() {
        while heights.count > capacity, let oldest = order.first {
            order.removeFirst()
            heights.removeValue(forKey: oldest)
        }
    }
}
