import Foundation

public enum LaunchClock {
    private static let origin = ContinuousClock.now

    public static func begin() {
        _ = origin
    }

    public static var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    public static func mark(_ label: String, on diagnostics: Diagnostics) {
        diagnostics.info("launch", "\(label) +\(elapsedMilliseconds)ms")
    }
}
