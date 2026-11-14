import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeList(config: .fromArgs()) }
            #if os(macOS)
            .defaultSize(width: 420, height: 800)
            #endif
    }
}

enum Variant: String { case current, legacy, track, delta, bottom, flipped, flippedAnchor, flippedComp }

struct Config {
    let variant: Variant
    let deferUntilIdle: Bool
    let latencyMS: Int
    let total: Int
    let noop: Bool
    let appends: Bool
    let output: String

    static func fromArgs() -> Config {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        return Config(
            variant: Variant(rawValue: d.string(forKey: "variant") ?? "") ?? .current,
            deferUntilIdle: d.bool(forKey: "defer"),
            latencyMS: d.integer(forKey: "latency") == 0 ? 250 : d.integer(forKey: "latency"),
            total: d.integer(forKey: "total") == 0 ? 1000 : d.integer(forKey: "total"),
            noop: d.bool(forKey: "noop"),
            appends: d.bool(forKey: "appends"),
            output: env["SPIKE_OUT"] ?? d.string(forKey: "out") ?? NSTemporaryDirectory() + "spike.jsonl")
    }
}

struct Row: Identifiable, Equatable {
    let id: Int
    var height: CGFloat? {
        let h = abs((id &* 2654435761) % 1000)
        if h % 7 == 0 { return CGFloat(500 + h % 500) }
        return h % 2 == 0 ? CGFloat(44 + (h % 300)) : nil
    }
    var text: String {
        let n = 1 + abs((id &* 40503) % 30)
        return "Row \(id) " + String(repeating: "lorem ipsum dolor sit amet ", count: n)
    }
}

@MainActor
final class Probe {
    var minY: [Int: CGFloat] = [:]
    var offsetY: CGFloat = 0
    var contentH: CGFloat = 0
    var viewportH: CGFloat = 0
    var phase: ScrollPhase = .idle
    var materialized: Set<Int> = []
    var topVisible: Int?
    let file: FileHandle?

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
    }

    func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        file?.write(data + Data("\n".utf8))
        try? file?.synchronize()
    }

    func anchor() -> (Int, CGFloat)? {
        minY.filter { $0.value >= 0 && $0.value < viewportH }.min { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

struct SpikeList: View {
    let config: Config
    static let page = 40
    @State private var rows: [Row]
    @State private var probe: Probe
    @State private var pos = ScrollPosition(idType: Int.self, edge: .bottom)
    @State private var topID: Int?
    @State private var loading = false
    @State private var pending: [Row]?
    @State private var loads = 0
    @State private var status = "ready"
    @State private var pendingNoop: [Row]?
    @State private var grown = 0
    @State private var appendsDone = 0

    init(config: Config) {
        self.config = config
        _probe = State(initialValue: Probe(path: config.output))
        _pos = State(initialValue: ScrollPosition(idType: Int.self, edge: config.variant == .flippedComp ? .top : .bottom))
        _rows = State(initialValue: ((config.total - 60)..<config.total).map(Row.init))
    }

    var flipped: Bool { [.flipped, .flippedAnchor, .flippedComp].contains(config.variant) }
    var nearTop: Bool {
        flipped ? probe.contentH - probe.offsetY - probe.viewportH < probe.viewportH * 2 : probe.offsetY < probe.viewportH * 2
    }
    var atStart: Bool { rows.first?.id == 0 }

    var body: some View {
        VStack(spacing: 0) {
            Text("appends \(appendsDone)").font(.caption2).accessibilityIdentifier("appends")
            Text(status).font(.caption).accessibilityIdentifier("status")
            configured(
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if !flipped { header }
                        ForEach(flipped ? rows.reversed() : rows) { row in
                            RowView(row: row, extra: row.id == rows.last?.id ? grown : 0)
                                .scaleEffect(y: flipped ? -1 : 1)
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    let f = proxy.frame(in: .scrollView)
                                    return flipped ? probe.viewportH - f.maxY : f.minY
                                } action: { probe.minY[row.id] = $0 }
                                .onAppear { probe.materialized.insert(row.id) }
                                .onDisappear { probe.minY[row.id] = nil }
                        }
                        if flipped { header.scaleEffect(y: -1) }
                    }
                    .scrollTargetLayout()
                }
                .accessibilityIdentifier("list")
                .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y + $0.contentInsets.top, $0.contentSize.height, $0.containerSize.height] } action: { _, v in
                    probe.offsetY = v[0]; probe.contentH = v[1]; probe.viewportH = v[2]
                    demand()
                }
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in probe.topVisible = ids.first }
                .task { if config.appends { await streamLoop() } }
                .task { await publishWindowCenter() }
                .onScrollPhaseChange { _, p in
                    probe.phase = p
                    if p == .idle { flushDeferred() }
                    demand()
                }
            )
        }
    }

    @ViewBuilder
    var header: some View {
        if atStart {
            Text("Start").frame(height: 60).accessibilityIdentifier("start")
        } else {
            ProgressView().frame(height: 60)
        }
    }

    @ViewBuilder
    func configured<V: View>(_ v: V) -> some View {
        switch config.variant {
        case .legacy:
            v.scrollPosition(id: $topID, anchor: .top).defaultScrollAnchor(.bottom, for: .initialOffset)
        case .current, .track, .delta:
            v.scrollPosition($pos).defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.top, for: .sizeChanges)
        case .bottom:
            v.scrollPosition($pos).defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
        case .flipped:
            v.scaleEffect(y: -1)
        case .flippedComp:
            v.scrollPosition($pos).scaleEffect(y: -1)
        case .flippedAnchor:
            v.defaultScrollAnchor(.bottom, for: .sizeChanges).scaleEffect(y: -1)
        }
    }

    func demand() {
        guard nearTop, !loading, pending == nil, !atStart, probe.viewportH > 0 else { return }
        loading = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(config.latencyMS))
            let lo = rows.first!.id
            let page = (max(0, lo - Self.page)..<lo).map(Row.init)
            loading = false
            if config.deferUntilIdle, probe.phase != .idle {
                pending = page
            } else {
                await apply(page)
            }
        }
    }

    func streamLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            guard probe.phase == .idle, !loading, let (anchorID, before) = probe.anchor() else { continue }
            let reading = flipped ? probe.offsetY > probe.viewportH : probe.contentH - probe.offsetY - probe.viewportH > probe.viewportH
            guard reading else { continue }
            var trace: [[Double]] = []
            let t0 = Date()
            func sample() { trace.append([Date().timeIntervalSince(t0) * 1000, Double(probe.minY[anchorID] ?? -99999), Double(probe.offsetY)]) }
            sample()
            if UserDefaults.standard.bool(forKey: "insertNew") { rows.append(Row(id: rows.last!.id + 1)) } else { grown += 3 }
            appendsDone += 1
            if config.variant == .flippedComp {
                for _ in 0..<40 {
                    if let now = probe.minY[anchorID], abs(now - before) > 0.5, probe.phase == .idle {
                        pos.scrollTo(y: probe.offsetY - (now - before))
                    }
                    try? await Task.sleep(for: .milliseconds(4))
                }
            }
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline { try? await Task.sleep(for: .milliseconds(8)); sample() }
            probe.emit(["event": "append", "anchor": anchorID, "before": Double(before), "offset": Double(probe.offsetY), "trace": trace])
        }
    }

    func publishWindowCenter() async {
        #if os(macOS)
        try? await Task.sleep(for: .milliseconds(800))
        guard let window = NSApp.windows.first(where: \.isVisible), let screen = window.screen ?? NSScreen.main else { return }
        let f = window.frame
        let center = "\(Int(f.midX)) \(Int(screen.frame.maxY - f.midY))"
        try? center.write(toFile: config.output + ".win", atomically: true, encoding: .utf8)
        #endif
    }

    func flushDeferred() {
        guard let page = pending else { return }
        pending = nil
        Task { @MainActor in await apply(page) }
    }

    func apply(_ page: [Row]) async {
        guard let (anchorID, before) = probe.anchor() else { rows.insert(contentsOf: page, at: 0); return }
        var trace: [[Double]] = []
        let t0 = Date()
        func sample() { trace.append([Date().timeIntervalSince(t0) * 1000, Double(probe.minY[anchorID] ?? -99999), Double(probe.offsetY)]) }
        for _ in 0..<4 { sample(); try? await Task.sleep(for: .milliseconds(8)) }
        let phaseAtPrepend = "\(probe.phase)"
        let beforeNow = probe.minY[anchorID] ?? before
        let offsetBefore = probe.offsetY
        let mutateAt = trace.count
        if config.noop { pendingNoop = page } else { rows.insert(contentsOf: page, at: 0) }
        loads += 1
        status = "loads \(loads)"
        compensate(anchorID: anchorID, beforeY: beforeNow, offsetBefore: offsetBefore)
        let deadline = Date().addingTimeInterval(1.1)
        while Date() < deadline { sample(); try? await Task.sleep(for: .milliseconds(8)) }
        if let held = pendingNoop { pendingNoop = nil; rows.insert(contentsOf: held, at: 0) }
        probe.emit(["event": "prepend", "load": loads, "variant": config.variant.rawValue, "defer": config.deferUntilIdle,
                    "anchor": anchorID, "phase": phaseAtPrepend, "mutateAt": mutateAt, "trace": trace,
                    "materialized": probe.materialized.count])
        if atStart {
            status = "top"
            probe.emit(["event": "done", "loads": loads, "materialized": Array(probe.materialized).sorted()])
        }
        demand()
    }

    func compensate(anchorID: Int, beforeY: CGFloat, offsetBefore: CGFloat) {
        switch config.variant {
        case .current, .legacy, .bottom, .flipped, .flippedAnchor, .flippedComp:
            return
        case .track:
            pos.scrollTo(id: anchorID, anchor: .top)
            Task { @MainActor in
                await Task.yield()
                pos.scrollTo(y: probe.offsetY - beforeY)
            }
        case .delta:
            Task { @MainActor in
                for _ in 0..<3 {
                    await Task.yield()
                    if let now = probe.minY[anchorID], abs(now - beforeY) > 0.5 {
                        pos.scrollTo(y: probe.offsetY + (now - beforeY))
                    }
                }
            }
        }
    }
}

struct RowView: View {
    let row: Row
    var extra = 0
    var body: some View {
        VStack(spacing: 0) {
            content
            ForEach(0..<extra, id: \.self) { i in Text("streamed line \(i)").frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    @ViewBuilder
    var content: some View {
        Group {
            if let h = row.height {
                Text("Row \(row.id) h\(Int(h))").frame(maxWidth: .infinity, minHeight: h, maxHeight: h)
            } else {
                Text(row.text).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .background(Color(hue: Double(abs(row.id) % 12) / 12, saturation: 0.3, brightness: 0.95))
    }
}
