import Foundation

public struct StreamCommitGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case commitNow
        case wait(Duration)
    }

    public static let defaultInterval = Duration.milliseconds(150)

    public var interval: Duration
    private var lastCommit: ContinuousClock.Instant?

    public init(interval: Duration = StreamCommitGate.defaultInterval) {
        self.interval = interval
    }

    public mutating func offer(at now: ContinuousClock.Instant, final: Bool) -> Decision {
        if !final, let lastCommit {
            let elapsed = lastCommit.duration(to: now)
            if elapsed < interval { return .wait(interval - elapsed) }
        }
        lastCommit = now
        return .commitNow
    }

    public mutating func committed(at now: ContinuousClock.Instant) {
        lastCommit = now
    }

    public mutating func reset() {
        lastCommit = nil
    }
}

public enum StreamingHeightReserve {
    public static let tolerance = 0.05

    public static func reserved(measured: Double, current: Double, line: Double) -> Double {
        guard line > 0, measured > 0 else { return current }
        let lines = (measured / line - tolerance).rounded(.up)
        return max(current, lines * line)
    }
}
