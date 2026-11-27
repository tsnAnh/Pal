import Foundation

public struct ChatRowWindow: Sendable, Equatable {
    public static let size = 200
    public static let page = 100
    public static let ceiling = 400

    private var startID: String?
    private var firstID: String?

    public init() {}

    public mutating func resolve(_ ids: [String]) -> Range<Int> {
        defer { firstID = ids.first }
        if let head = ids.first, startID != nil, startID == firstID, startID != head, ids.count <= Self.ceiling { startID = head }
        let window = range(in: ids)
        startID = window.isEmpty ? nil : ids[window.lowerBound]
        return window
    }

    @discardableResult
    public mutating func expand(_ ids: [String]) -> Bool {
        let lower = range(in: ids).lowerBound
        guard lower > 0 else { return false }
        startID = ids[max(0, lower - Self.page)]
        return true
    }

    @discardableResult
    public mutating func reveal(_ id: String, in ids: [String]) -> Bool {
        guard let index = ids.firstIndex(of: id), index < range(in: ids).lowerBound else { return false }
        startID = ids[max(0, index - Self.page / 2)]
        return true
    }

    @discardableResult
    public mutating func trim(_ ids: [String]) -> Bool {
        guard range(in: ids).count > Self.ceiling else { return false }
        startID = ids[ids.count - Self.size]
        return true
    }

    private func range(in ids: [String]) -> Range<Int> {
        guard let startID, let index = ids.firstIndex(of: startID) else { return max(0, ids.count - Self.size)..<ids.count }
        return index..<ids.count
    }
}
