import Foundation
import Synchronization

public enum ChatOpenTrace {
    public static let fileName = "pal-chat-open.jsonl"

    private static let enabled = PalPerf.isRequested()
    private static let sink = Sink()
    private static let state = Mutex(State())

    private struct State {
        var starts: [String: ContinuousClock.Instant] = [:]
        var opens: [String: Int] = [:]
        var newestVersion: [String: UInt64] = [:]
        var framed: Set<String> = []
    }

    private struct Line: Encodable {
        let bot: String
        let step: String
        let ms: Double
        let open: Int
        let cachedSeq: Int?
        let gatewaySeq: Int?
        let rows: Int?
        let detail: String?
    }

    public static func begin(bot: String) {
        guard enabled else { return }
        state.withLock { state in
            state.starts[bot] = .now
            state.opens[bot, default: 0] += 1
            state.newestVersion[bot] = nil
            state.framed.remove(bot)
        }
        mark(bot, "open.tap")
    }

    public static func finish(bot: String) {
        guard enabled else { return }
        state.withLock { state in
            state.starts[bot] = nil
            state.newestVersion[bot] = nil
            state.framed.remove(bot)
        }
    }

    public static func mark(
        _ bot: String,
        _ step: String,
        cachedSequence: Int? = nil,
        gatewaySequence: Int? = nil,
        rows: Int? = nil,
        detail: String? = nil
    ) {
        guard enabled else { return }
        let (start, open) = state.withLock { ($0.starts[bot], $0.opens[bot] ?? 0) }
        guard let start else { return }
        PalPerf.event("chat.open.step", label: "\(bot) \(step)", since: start)
        let elapsed = start.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        sink.append(Line(
            bot: bot, step: step, ms: ms, open: open, cachedSeq: cachedSequence, gatewaySeq: gatewaySequence,
            rows: rows, detail: detail
        ))
    }

    public static func noteNewest(bot: String, version: UInt64) {
        guard enabled else { return }
        state.withLock { $0.newestVersion[bot] = version }
    }

    public static func frameApplied(bot: String, version: UInt64, rows: Int) {
        guard enabled else { return }
        let reached = state.withLock { state -> Bool in
            guard let newest = state.newestVersion[bot], version >= newest, !state.framed.contains(bot) else { return false }
            state.framed.insert(bot)
            return true
        }
        if reached { mark(bot, "frame.newest", rows: rows) }
    }

    private final class Sink: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.pal.chat-open-trace", qos: .utility)
        private let url: URL
        private let encoder = JSONEncoder()
        private var handle: FileHandle?

        init() {
            let directory = ProcessInfo.processInfo.environment[PalPerf.directoryKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            url = directory.appending(path: ChatOpenTrace.fileName)
        }

        func append(_ line: Line) {
            queue.async { [self] in
                guard var data = try? encoder.encode(line) else { return }
                data.append(0x0A)
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                    handle = try? FileHandle(forWritingTo: url)
                    _ = try? handle?.seekToEnd()
                }
                try? handle?.write(contentsOf: data)
            }
        }
    }
}
