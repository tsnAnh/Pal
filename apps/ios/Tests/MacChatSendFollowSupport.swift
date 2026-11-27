#if os(macOS)
import AppKit
import Foundation
import PalChat
import PalProtocol
import Synchronization
import Testing

@testable import Pal

struct SendFollowShape: CustomTestStringConvertible, Sendable {
    let name: String
    let history: Int
    let running: Bool
    var scrollsFirst = false

    var testDescription: String { name }
}

struct SendFollowSample {
    let milliseconds: Double
    let distance: Double
    let state: String
    let button: Bool
    let delivered: Int
    let rowOrder: [String]

    var isAtNewest: Bool { distance <= ChatScrollMachine.atBottomTolerance && state == "pinnedToBottom" }
}

private final class SendFollowSubmits: Sendable {
    let all = Mutex<[(id: String, text: String)]>([])
}

@MainActor
final class SendFollowStage {
    static let pane = CGSize(width: 985, height: 560)
    static let texts = ["still seeing this one", "see it?"]
    static let turnStartDelay = Duration.milliseconds(500)
    static let observed = Duration.milliseconds(1_500)

    let scroll = ChatScrollController()
    private let model: ChatModel
    private let host: MacChatBenchHost
    private let draft = MacChatBenchDraft()
    private let script: TimelineScript
    private let gateway: FakeGateway
    private let root: URL
    private let submits = SendFollowSubmits()
    private var laidOut: [String: ContinuousClock.Instant] = [:]

    init(shape: SendFollowShape, admission: Duration) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "send-follow-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.root = root
        let script = TimelineScript(entries: Self.history(shape.history))
        self.script = script
        let submits = submits
        script.override("prompt.submit") { number in .delayed(admission, ["admission_id": .string("a-\(number)"), "status": "queued"]) }
        gateway = try await FakeGateway.start { method, params, connection in
            if method == "prompt.submit" {
                submits.all.withLock { $0.append((params?["submission_id"]?.stringValue ?? "", params?["text"]?.stringValue ?? "")) }
            }
            return script.handle(method, params, connection)
        }
        let url = gateway.url
        model = try rebuildChatModel(makeLinks: { connection in
            BotLinks(
                connection: connection, drafts: DraftStore(directory: root.appending(path: "drafts")),
                connector: ScriptedConnector(url: url, runtime: script.runtime, requestTimeout: .seconds(30)),
                outboxRoot: root.appending(path: "outbox")
            )
        })
        let environment = MacChatBenchEnvironment(model: model)
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: scroll), size: Self.pane)
        scroll.rowSink = { [weak self] id, _ in
            if self?.laidOut[id] == nil { self?.laidOut[id] = .now }
        }
        NSApplication.shared.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try await open(running: shape.running)
        if shape.scrollsFirst { try await trackpadScrollAtNewest() }
    }

    private static func history(_ count: Int) -> [TimelineEntryWire] {
        let long = String(repeating: "The account balance is running low and a top up can take a few days to clear. ", count: 5)
        let start = Date().timeIntervalSince1970 - 20_000
        var rows = (0..<count).map { index in
            TimelineEntryWire(
                id: "h\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
                text: index.isMultiple(of: 2) ? "question \(index)" : "\(long)\n\n- first \(index)\n- second\n- third",
                timestamp: start + Double(index), rowID: index + 1
            )
        }
        rows.append(TimelineEntryWire(id: "h-long", role: .assistant, text: long + long, timestamp: start + 18_000, rowID: count + 1))
        rows.append(TimelineEntryWire(id: "h-test", role: .user, text: "test", timestamp: start + 19_000, rowID: count + 2))
        rows.append(TimelineEntryWire(id: "h-reply", role: .assistant, text: "Got \"test\".", timestamp: start + 19_001, rowID: count + 3))
        return rows
    }

    private func open(running: Bool) async throws {
        model.start()
        try await until { self.model.connection == .live && !self.model.rows.isEmpty && !self.model.isOpening }
        if running {
            gateway.push(script.event("message.start", seq: 2, payload: ["turn_id": "t0"]))
            try await until { self.model.isRunning }
        }
        try await Task.sleep(for: .milliseconds(900))
        host.settleAtNewest(maxFrames: 240)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func trackpadScrollAtNewest() async throws {
        let scrollView = try #require(host.transcriptScrollView)
        let gesture: [(phase: CGScrollPhase, delta: Int32)] = [(.began, -4), (.changed, -12), (.ended, 0)]
        for step in gesture {
            let event = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: step.delta, wheel2: 0, wheel3: 0
            ))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(step.phase.rawValue))
            scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(1_000))
        try #require(!scroll.machine.isUserScrolling)
    }

    func close() {
        model.stop()
        host.close()
        gateway.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func element(_ identifier: String) throws -> NSObject {
        var found: NSObject?
        func walk(_ node: Any) {
            guard found == nil, let object = node as? NSObject else { return }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier,
               object.responds(to: Selector(("accessibilityPerformPress"))) {
                found = object
                return
            }
            guard object.responds(to: Selector(("accessibilityChildren"))),
                  let children = object.value(forKey: "accessibilityChildren") as? [Any] else { return }
            children.forEach(walk)
        }
        walk(host.view)
        return try #require(found, "no \(identifier) in the composer")
    }

    private func userRows(_ texts: [String]) -> [ChatRow] {
        model.rows.filter { row in
            if case .user(let text, _) = row.kind { texts.contains(text) } else { false }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private func distance() -> Double {
        guard let scrollView = host.transcriptScrollView, let document = scrollView.documentView else { return .infinity }
        let clip = scrollView.contentView
        let newest = Double(document.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        return max(0, newest - Double(clip.bounds.origin.y))
    }

    private func sample(since start: ContinuousClock.Instant, texts: [String]) -> SendFollowSample {
        let rows = userRows(texts)
        return SendFollowSample(
            milliseconds: Self.milliseconds(start.duration(to: .now)), distance: distance(),
            state: scroll.machine.state.name, button: scroll.showsJumpButton,
            delivered: rows.count { if case .user(_, .sent) = $0.kind { true } else { false } },
            rowOrder: rows.compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
        )
    }

    private func observe(since start: ContinuousClock.Instant, texts: [String], startingTurn: Bool = false) async throws -> [SendFollowSample] {
        var samples: [SendFollowSample] = []
        var turnPending = startingTurn
        while start.duration(to: .now) < Self.observed {
            if turnPending, start.duration(to: .now) >= Self.turnStartDelay {
                gateway.push(script.event("message.start", seq: 3, payload: ["turn_id": "t1"]))
                turnPending = false
            }
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            samples.append(sample(since: start, texts: texts))
        }
        return samples
    }

    func send(_ count: Int, startsTurn: Bool) async throws -> SendFollowMeasure {
        let sent = Array(Self.texts.prefix(count))
        draft.text = sent[count - 1]
        try await Task.sleep(for: .milliseconds(250))
        let button = try element("sendButton")
        let start = ContinuousClock.now
        _ = button.perform(Selector(("accessibilityPerformPress")))
        let inModel = userRows(sent).count
        let samples = try await observe(since: start, texts: sent, startingTurn: startsTurn)
        let drawn = userRows(sent).last.flatMap { laidOut[$0.id] }.map { Self.milliseconds(start.duration(to: $0)) }
        return SendFollowMeasure(sent: sent, inModelAtPress: inModel, drawn: drawn, samples: samples)
    }

    func takeServerRows(running: Bool) async throws -> SendFollowSample {
        try await until(.seconds(15)) { self.sample(since: .now, texts: Self.texts).delivered == Self.texts.count }
        for item in submits.all.withLock({ $0 }) {
            let rowID = 900 + script.entries.withLock { $0.count }
            script.append([TimelineEntryWire(
                id: "srv-\(rowID)", role: .user, text: item.text, timestamp: Date().timeIntervalSince1970,
                displayMetadata: ["submission_id": .string(item.id)], rowID: rowID
            )])
        }
        let served = ContinuousClock.now
        gateway.push(script.event("message.complete", seq: 20, payload: [
            "text": "Looking into it.", "turn_id": .string(running ? "t0" : "t1"), "message_uid": "srv-reply",
        ]))
        try await until { self.model.snapshot?.rows.count { $0.item.id.hasPrefix("srv-9") } == Self.texts.count }
        try await Task.sleep(for: .milliseconds(600))
        return sample(since: served, texts: Self.texts)
    }

    private func until(_ timeout: Duration = .seconds(10), _ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !predicate() {
            try #require(ContinuousClock.now < end, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct SendFollowMeasure {
    static let settleMilliseconds = 100.0

    let sent: [String]
    let inModelAtPress: Int
    let drawn: Double?
    let samples: [SendFollowSample]

    private var followed: Double? { samples.first { $0.isAtNewest && $0.rowOrder.count == sent.count }?.milliseconds }
    private var away: [SendFollowSample] { samples.filter { $0.milliseconds >= Self.settleMilliseconds && !$0.isAtNewest } }
    private var chevrons: Int { samples.count { $0.button } }

    var line: String {
        let farthest = samples.map(\.distance).max() ?? 0
        return "send \(sent.count): model=\(inModelAtPress == sent.count ? "at press" : "late") drawn=\(show(drawn)) bottom=\(show(followed)) "
            + "away=\(away.count)/\(samples.count) chevron=\(chevrons) maxDistance=\(Int(farthest)) "
            + "endDistance=\(Int(samples.last?.distance ?? -1)) state=\(samples.last?.state ?? "none")"
    }

    var failures: [String] {
        var found: [String] = []
        if inModelAtPress != sent.count { found.append("send \(sent.count) not in the model at the press") }
        if drawn.map({ $0 > Self.settleMilliseconds }) ?? true { found.append("send \(sent.count) drawn \(show(drawn))") }
        if !away.isEmpty { found.append("send \(sent.count) away from the newest row in \(away.count) samples after 100 ms") }
        if chevrons > 0 { found.append("send \(sent.count) showed the jump button") }
        if samples.last?.rowOrder != sent { found.append("send \(sent.count) rows \(samples.last?.rowOrder ?? [])") }
        return found
    }

    private func show(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "never"
    }
}
#endif
