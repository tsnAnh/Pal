import Foundation
import PalChat
import PalDiagnostics
import SwiftUI

@MainActor
enum ChatScrollTrace {
    nonisolated static let environmentKey = "PAL_SCROLL_TRACE"
    nonisolated static let fileName = "pal-scroll-trace.csv"
    nonisolated static let layout = "top-down"
    nonisolated static let header = [
        "epoch_s", "kind", "reason", "mode", "phase", "offset_y", "inset_top", "inset_bottom", "content_h",
        "container_h", "distance", "safe_top", "safe_bottom", "pin", "pin_min_y", "rows", "layout", "width",
        "event", "state", "command",
    ].joined(separator: ",") + "\n"
    static let isOn = ProcessInfo.processInfo.environment[environmentKey] == "1"

    private static let flushEvery = 120
    private static var lastGeometry: ChatScrollGeometry?
    private static var lastState = ""
    private static var lastPhase = "idle"
    private static var lastRows = 0
    private static var pending: [String] = []
    private static var log: TraceFile?

    static func geometry(_ value: ChatScrollGeometry, state: String) {
        guard isOn else { return }
        lastGeometry = value
        lastState = state
        record("geo")
    }

    static func phase(_ value: ScrollPhase, state: String) {
        guard isOn else { return }
        lastPhase = "\(value)"
        lastState = state
        record("phase")
    }

    static func rows(_ count: Int, state: String) {
        guard isOn else { return }
        lastRows = count
        lastState = state
        record("rows")
    }

    static func machine(event: String, state: String, command: String) {
        guard isOn else { return }
        lastState = state
        record("machine", reason: event, event: event, command: command)
    }

    private static func record(_ kind: String, reason: String = "", event: String = "", command: String = "") {
        let anchor = lastGeometry?.topAnchor
        let fields: [String] = [
            String(format: "%.6f", Date().timeIntervalSince1970), kind, reason, lastState, lastPhase,
            number(lastGeometry?.offsetY), number(lastGeometry?.insetTop), number(lastGeometry?.insetBottom),
            number(lastGeometry?.contentHeight), number(lastGeometry?.containerHeight), number(lastGeometry?.distanceFromBottom),
            "", "", anchor.map { String($0.rowID.hashValue) } ?? "", number(anchor.map { -$0.offsetInRow }), String(lastRows),
            layout, number(lastGeometry?.containerWidth), event, kind == "machine" ? lastState : "", command,
        ]
        pending.append(fields.joined(separator: ",") + "\n")
        guard pending.count >= flushEvery || kind == "phase" else { return }
        flush()
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? ""
    }

    private static func flush() {
        let file = log ?? TraceFile()
        log = file
        file.append(pending.joined())
        pending.removeAll(keepingCapacity: true)
    }
}

private final class TraceFile: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app.pal.scroll-trace", qos: .utility)

    init() {
        let directory = ProcessInfo.processInfo.environment[PalPerf.directoryKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = directory.appending(path: ChatScrollTrace.fileName)
        queue.async { [url] in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(ChatScrollTrace.header.utf8).write(to: url, options: .atomic)
        }
    }

    func append(_ text: String) {
        let data = Data(text.utf8)
        queue.async { [url] in
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
