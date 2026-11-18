import Foundation
import os

public enum PalPerf {
    public static let environmentKey = "PAL_PERF"
    public static let directoryKey = "PAL_PERF_DIR"
    public static let defaultsKey = "palPerf"

    public static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        environment[environmentKey] == "1" || defaults.bool(forKey: defaultsKey)
    }

    nonisolated(unsafe) private static let signposter = OSSignposter(subsystem: "app.pal", category: "perf")

    public static func begin(_ name: StaticString) -> PerfInterval {
        guard signposter.isEnabled else { return PerfInterval(name: name, state: nil) }
        return PerfInterval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    public static func interval<Result>(_ name: StaticString, _ body: () throws -> Result) rethrows -> Result {
        let interval = begin(name)
        defer { interval.end() }
        return try body()
    }

    public static func mainDiskRead<Result>(_ body: () throws -> Result) rethrows -> Result {
        try interval("disk.sync.main", body)
    }

    public static func event(_ name: StaticString) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(name)
    }

    public static func event(_ name: StaticString, count: Int) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(name, "\(count)")
    }

    fileprivate static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

public struct PerfInterval {
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState?

    public func end() {
        guard let state else { return }
        PalPerf.end(name, state)
    }
}
