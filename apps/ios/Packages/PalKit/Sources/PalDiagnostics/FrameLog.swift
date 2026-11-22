import Foundation

struct FrameSample: Sendable, Equatable {
    var epochSeconds: Double
    var intervalMs: Double
    var budgetMs: Double
}

final class FrameLog: Sendable {
    static let fileName = "pal-frames.csv"
    static let header = "epoch_s,interval_ms,budget_ms\n"

    private let url: URL
    private let diagnostics: Diagnostics
    private let queue = DispatchQueue(label: "app.pal.frame-log", qos: .utility)

    init(url: URL, diagnostics: Diagnostics) {
        self.url = url
        self.diagnostics = diagnostics
        queue.async { [url, diagnostics] in
            Self.perform("frame log not created", diagnostics) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(Self.header.utf8).write(to: url, options: .atomic)
            }
        }
    }

    static func rows(_ samples: [FrameSample]) -> String {
        samples.map { String(format: "%.6f,%.3f,%.3f\n", $0.epochSeconds, $0.intervalMs, $0.budgetMs) }.joined()
    }

    func append(_ samples: [FrameSample], synchronously: Bool) {
        guard !samples.isEmpty else {
            if synchronously { queue.sync {} } // perf-lint: ok drains pending frame writes once, at terminate
            return
        }
        let data = Data(Self.rows(samples).utf8)
        let work = { [url, diagnostics] in
            Self.perform("frame log not written", diagnostics) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) } // perf-lint: ok writes the last frames once, at terminate
    }

    private static func perform(_ failure: String, _ diagnostics: Diagnostics, _ body: () throws -> Void) {
        do { try body() } catch { diagnostics.warning("perf", "\(failure): \(Diagnostics.describe(error))") }
    }
}
