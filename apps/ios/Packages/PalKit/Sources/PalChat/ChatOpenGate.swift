import Foundation

public struct ChatOpenGate: Sendable {
    public static let bound = Duration.seconds(1)

    private var cachedVersion: UInt64?
    private var held: TimelineSnapshot?

    public init() {}

    public var isHolding: Bool { cachedVersion != nil }

    public mutating func hold(version: UInt64) {
        cachedVersion = version
    }

    public mutating func admit(_ next: TimelineSnapshot) -> TimelineSnapshot? {
        guard let cachedVersion else { return next }
        guard next.version <= cachedVersion else {
            self.cachedVersion = nil
            held = nil
            return next
        }
        held = next
        return nil
    }

    public mutating func release() -> TimelineSnapshot? {
        guard cachedVersion != nil else { return nil }
        cachedVersion = nil
        defer { held = nil }
        return held
    }
}
