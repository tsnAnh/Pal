#if os(macOS)
import Foundation

struct MacChatBenchScenario: Codable, Equatable {
    var name: String
    var steps: Int
    var p50: Double
    var p95: Double
    var max: Double
    var over8: Int
    var over16: Int
    var total: Double
    var samples: [Double]
    var wallP95: Double
    var wall: [Double]

    init(name: String, samples: [Double], wall: [Double]) {
        let sorted = samples.sorted()
        self.name = name
        self.samples = samples
        self.wall = wall
        wallP95 = Self.percentile(wall.sorted(), 0.95)
        steps = samples.count
        p50 = Self.percentile(sorted, 0.50)
        p95 = Self.percentile(sorted, 0.95)
        max = sorted.last ?? 0
        over8 = samples.filter { $0 > 1000.0 / 120.0 }.count
        over16 = samples.filter { $0 > 1000.0 / 60.0 }.count
        total = samples.reduce(0, +)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[rank]
    }
}

struct MacChatBenchReport: Codable {
    var schema = 1
    var generated: String
    var paneWidth: Double
    var paneHeight: Double
    var transcriptMessages: Int
    var os: String
    var openFrames: [Int]
    var openRetries: Int
    var scenarios: [MacChatBenchScenario]

    func table() -> String {
        let header = "scenario".padding(toLength: 18, withPad: " ", startingAt: 0)
            + ["steps", "p50", "p95", "max", ">8.33", ">16.7", "total"].map { $0.leftPadded(8) }.joined()
        let rows = scenarios.map { scenario in
            scenario.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                + [
                    String(scenario.steps), scenario.p50.ms, scenario.p95.ms, scenario.max.ms,
                    String(scenario.over8), String(scenario.over16), scenario.total.ms,
                ].map { $0.leftPadded(8) }.joined()
        }
        return ([header] + rows).joined(separator: "\n")
    }

    func write(to directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: name))
    }
}

private extension Double {
    var ms: String { String(format: "%.2f", self) }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        String(repeating: " ", count: Swift.max(0, width - count)) + self
    }
}
#endif
