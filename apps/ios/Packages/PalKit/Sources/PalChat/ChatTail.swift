import Foundation

public struct ChatTailPlan: Sendable, Equatable {
    public var start: Int
    public var hiddenHeight: Double

    public init(start: Int, hiddenHeight: Double) {
        self.start = start
        self.hiddenHeight = hiddenHeight
    }
}

public struct ChatTail: Sendable, Equatable {
    public static let viewports = 1.5
    public static let minimumRows = 8
    public static let fallbackRows = 16
    public static let pageRows = 12
    private static let revealMargin = 4

    public private(set) var startID: String?
    private var revealedAll = false

    public init() {}

    public func start(in ids: [String]) -> Int {
        guard let startID, let index = ids.firstIndex(of: startID) else { return 0 }
        return index
    }

    public mutating func plan(ids: [String], viewport: Double?, height: (String) -> Double) -> ChatTailPlan {
        if ids.isEmpty { return ChatTailPlan(start: 0, hiddenHeight: 0) }
        if !revealedAll, startID.map({ ids.contains($0) }) != true {
            choose(ids: ids, viewport: viewport, height: height)
        }
        let first = start(in: ids)
        return ChatTailPlan(start: first, hiddenHeight: Self.sum(ids, upTo: first, height: height))
    }

    public mutating func extend(ids: [String], deficit: Double, height: (String) -> Double) -> Bool {
        let current = start(in: ids)
        guard current > 0 else { return false }
        let wanted = max(deficit, 0)
        var index = current
        var revealed = 0.0
        var taken = 0
        while index > 0, revealed < wanted || taken < Self.pageRows {
            index -= 1
            revealed += height(ids[index])
            taken += 1
        }
        move(to: index, in: ids)
        return true
    }

    public mutating func reveal(_ id: String, in ids: [String]) -> Bool {
        guard let index = ids.firstIndex(of: id), index < start(in: ids) else { return false }
        move(to: max(0, index - Self.revealMargin), in: ids)
        return true
    }

    public mutating func reset() {
        startID = nil
        revealedAll = false
    }

    private mutating func choose(ids: [String], viewport: Double?, height: (String) -> Double) {
        var index = ids.count
        if let viewport {
            let target = Self.viewports * viewport
            var covered = 0.0
            var taken = 0
            while index > 0, covered < target || taken < Self.minimumRows {
                index -= 1
                covered += height(ids[index])
                taken += 1
            }
        } else {
            index = max(0, ids.count - Self.fallbackRows)
        }
        startID = index == 0 ? nil : ids[index]
    }

    private mutating func move(to index: Int, in ids: [String]) {
        if index <= 0 {
            startID = nil
            revealedAll = true
        } else {
            startID = ids[index]
        }
    }

    private static func sum(_ ids: [String], upTo end: Int, height: (String) -> Double) -> Double {
        var total = 0.0
        for index in 0..<end { total += height(ids[index]) }
        return total
    }
}
