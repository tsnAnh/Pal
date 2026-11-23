import Foundation
import PalDiagnostics
import SwiftUI

@MainActor
enum ChatScrollTrace {
    enum Reason: String {
        case openPin = "open-pin"
        case openNewest = "open-newest"
        case anchor
        case drift
        case keepNewestRows = "keep-newest-rows"
        case keepNewestGrew = "keep-newest-grew"
        case keepNewestChrome = "keep-newest-chrome"
        case jump
        case reveal
        case revealRetry = "reveal-retry"
    }

    nonisolated static let environmentKey = "PAL_SCROLL_TRACE"
    nonisolated static let fileName = "pal-scroll-trace.csv"
    nonisolated static let header = [
        "epoch_s", "kind", "reason", "mode", "phase", "offset_y", "inset_top", "inset_bottom", "content_h",
        "container_h", "distance", "safe_top", "safe_bottom", "pin", "pin_min_y", "rows",
    ].joined(separator: ",") + "\n"
    static let isOn = ProcessInfo.processInfo.environment[environmentKey] == "1"

    private static let flushEvery = 120
    private static var lastGeometry: ScrollGeometry?
    private static var lastSafeArea = EdgeInsets()
    private static var lastMode = ""
    private static var lastPhase = "idle"
    private static var lastPin: Int?
    private static var lastPinMinY: CGFloat?
    private static var lastRows = 0
    private static var pending: [String] = []
    private static var log: TraceFile?

    static func geometry(_ value: ScrollGeometry) {
        guard isOn else { return }
        lastGeometry = value
        record("geo")
    }

    static func chrome(_ value: EdgeInsets) {
        guard isOn else { return }
        lastSafeArea = value
        record("chrome")
    }

    static func phase(_ value: ScrollPhase, mode current: ChatScrollController.Mode) {
        guard isOn else { return }
        lastPhase = "\(value)"
        lastMode = "\(current)"
        record("phase")
    }

    static func pin(_ id: String, minY: CGFloat?, mode current: ChatScrollController.Mode) {
        guard isOn else { return }
        lastPin = id.hashValue
        lastPinMinY = minY
        lastMode = "\(current)"
        record("pin")
    }

    static func rows(_ count: Int, mode current: ChatScrollController.Mode) {
        guard isOn else { return }
        lastRows = count
        lastMode = "\(current)"
        record("rows")
    }

    static func write(_ reason: Reason, applied: Bool, mode current: ChatScrollController.Mode) {
        guard isOn else { return }
        lastMode = "\(current)"
        record(applied ? "write" : "skip", reason: reason.rawValue)
    }

    private static func record(_ kind: String, reason: String = "") {
        let fields: [String] = [
            String(format: "%.6f", Date().timeIntervalSince1970), kind, reason, lastMode, lastPhase,
            number(lastGeometry?.contentOffset.y), number(lastGeometry?.contentInsets.top), number(lastGeometry?.contentInsets.bottom),
            number(lastGeometry?.contentSize.height), number(lastGeometry?.containerSize.height),
            number(lastGeometry.map { $0.contentOffset.y + $0.contentInsets.top }),
            number(lastSafeArea.top), number(lastSafeArea.bottom),
            lastPin.map(String.init) ?? "", number(lastPinMinY), String(lastRows),
        ]
        pending.append(fields.joined(separator: ",") + "\n")
        guard pending.count >= flushEvery || kind == "phase" else { return }
        flush()
    }

    private static func number(_ value: CGFloat?) -> String {
        value.map { String(format: "%.2f", Double($0)) } ?? ""
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

struct ChatScrollTraceProbe: ViewModifier {
    let chrome: EdgeInsets

    func body(content: Content) -> some View {
        if ChatScrollTrace.isOn {
            content
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }, action: { _, new in ChatScrollTrace.geometry(new) })
                .onChange(of: chrome, initial: true) { _, value in ChatScrollTrace.chrome(value) }
        } else {
            content
        }
    }
}
