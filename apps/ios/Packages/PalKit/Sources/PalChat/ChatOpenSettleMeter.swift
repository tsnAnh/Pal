import Foundation

public struct ChatOpenSettleMeter: Sendable, Equatable {
    public struct Report: Sendable, Equatable {
        public var firstContent: Double
        public var settledContent: Double
        public var settleMilliseconds: Int
        public var maxPastEnd: Double
        public var rowsHitZero: Int
        public var overshootFactor: Double
    }

    public static let quietMilliseconds = 500
    public static let contentTolerance = 1.0

    private var firstTime: Int?
    private var latestTime = 0
    private var lastChangeTime = 0
    private var firstContent = 0.0
    private var latestContent = 0.0
    private var maxPastEnd = 0.0
    private var rowsHitZero = 0
    private var lastRowCount = 0

    public init() {}

    public mutating func geometry(_ geometry: ChatScrollGeometry, atMilliseconds time: Int) {
        if firstTime == nil {
            firstTime = time
            lastChangeTime = time
        } else if abs(geometry.contentHeight - latestContent) > Self.contentTolerance {
            lastChangeTime = time
        }
        if firstContent == 0, geometry.contentHeight > 0 { firstContent = geometry.contentHeight }
        latestContent = geometry.contentHeight
        latestTime = time
        if geometry.contentHeight > 0 { maxPastEnd = max(maxPastEnd, geometry.overshoot) }
    }

    public mutating func rows(count: Int) {
        if count == 0, lastRowCount > 0 { rowsHitZero += 1 }
        lastRowCount = count
    }

    public var isSettled: Bool {
        guard firstTime != nil else { return false }
        return latestTime - lastChangeTime >= Self.quietMilliseconds
    }

    public func report(atMilliseconds time: Int) -> Report {
        let settleMilliseconds = firstTime.map { lastChangeTime - $0 } ?? 0
        return Report(
            firstContent: firstContent,
            settledContent: latestContent,
            settleMilliseconds: settleMilliseconds,
            maxPastEnd: maxPastEnd,
            rowsHitZero: rowsHitZero,
            overshootFactor: latestContent > 0 ? firstContent / latestContent : 1
        )
    }
}
