import Foundation

public struct ChatPinnedShortWatch: Sendable, Equatable {
    public struct Episode: Sendable, Equatable {
        public let distance: Double
        public let milliseconds: Int

        public init(distance: Double, milliseconds: Int) {
            self.distance = distance
            self.milliseconds = milliseconds
        }
    }

    public static let frameMilliseconds = 1_000.0 / 60.0
    public static let allowedFrames = 2.0
    public static let limitMilliseconds = frameMilliseconds * allowedFrames

    public private(set) var episodes = 0
    private var since: Double?
    private var distance = 0.0
    private var reported = false

    public init() {}

    public var isShort: Bool { since != nil }

    public mutating func note(pinned: Bool, distance: Double, atMilliseconds now: Double) {
        guard pinned, distance > ChatScrollMachine.atBottomTolerance else {
            since = nil
            reported = false
            return
        }
        if since == nil { since = now }
        self.distance = distance
    }

    public mutating func overdue(atMilliseconds now: Double) -> Episode? {
        guard let since, !reported, now - since > Self.limitMilliseconds else { return nil }
        reported = true
        episodes += 1
        return Episode(distance: distance, milliseconds: Int(now - since))
    }
}
