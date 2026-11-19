import Foundation

public enum FrameClass: Sendable, Equatable {
    case smooth
    case hitch
    case severe
    case long
}

public struct LongHitch: Codable, Sendable, Equatable {
    public var atSeconds: Double
    public var ms: Double

    public init(atSeconds: Double, ms: Double) {
        self.atSeconds = atSeconds
        self.ms = ms
    }
}

public struct HitchReport: Codable, Sendable, Equatable {
    public struct Thresholds: Codable, Sendable, Equatable {
        public var hitch: Double
        public var severe: Double
    }

    public var schema: Int
    public var platform: String
    public var startedAt: String
    public var durationSeconds: Double
    public var frames: Int
    public var hitches: Int
    public var severeHitches: Int
    public var worstFrameMs: Double
    public var hitchMs: Double
    public var thresholdsMs: Thresholds
    public var longHitchThresholdMs: Double
    public var longHitchCount: Int
    public var longHitches: [LongHitch]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct HitchCounter: Sendable, Equatable {
    public static let hitchThresholdMs = 16.7
    public static let severeThresholdMs = 33.0
    public static let longThresholdMs = 100.0
    public static let longestKept = 10
    public static let reportSchema = 1

    public private(set) var frames = 0
    public private(set) var hitches = 0
    public private(set) var severeHitches = 0
    public private(set) var worstFrameMs = 0.0
    public private(set) var hitchMs = 0.0
    public private(set) var longHitchCount = 0
    public private(set) var longest: [LongHitch] = []

    public init() {}

    @discardableResult
    public mutating func record(frameMs: Double, atSeconds: Double = 0) -> FrameClass {
        frames += 1
        worstFrameMs = max(worstFrameMs, frameMs)
        guard frameMs > Self.hitchThresholdMs else { return .smooth }
        hitches += 1
        hitchMs += frameMs - Self.hitchThresholdMs
        guard frameMs > Self.severeThresholdMs else { return .hitch }
        severeHitches += 1
        guard frameMs > Self.longThresholdMs else { return .severe }
        longHitchCount += 1
        longest.append(LongHitch(atSeconds: atSeconds, ms: frameMs))
        longest.sort { $0.ms > $1.ms }
        if longest.count > Self.longestKept { longest.removeLast() }
        return .long
    }

    public func report(platform: String, startedAt: Date, durationSeconds: Double) -> HitchReport {
        HitchReport(
            schema: Self.reportSchema,
            platform: platform,
            startedAt: startedAt.formatted(.iso8601),
            durationSeconds: durationSeconds,
            frames: frames,
            hitches: hitches,
            severeHitches: severeHitches,
            worstFrameMs: worstFrameMs,
            hitchMs: hitchMs,
            thresholdsMs: .init(hitch: Self.hitchThresholdMs, severe: Self.severeThresholdMs),
            longHitchThresholdMs: Self.longThresholdMs,
            longHitchCount: longHitchCount,
            longHitches: longest
        )
    }
}
