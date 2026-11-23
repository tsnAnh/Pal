#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

struct OpenJumpEvent: CustomStringConvertible {
    let frame: Int
    let phase: String
    let row: Int
    let delta: CGFloat
    let offsetDelta: CGFloat
    let documentDelta: CGFloat

    var description: String {
        let moved = String(format: "%+.1f", delta)
        let offset = String(format: "%+.1f", offsetDelta)
        let document = String(format: "%+.1f", documentDelta)
        return "frame \(frame) [\(phase)] row \(row) moved \(moved)pt (clip offset \(offset), document \(document))"
    }
}

@MainActor
final class OpenJumpProbe {
    struct Sample {
        var rows: [Int: CGRect] = [:]
        var offset: CGFloat = 0
        var document: CGFloat = 0
    }

    let host: MacChatBenchHost
    private(set) var events: [OpenJumpEvent] = []
    private(set) var frame = 0
    private var previous: Sample?
    var phase = "start"
    var muted = false

    init(host: MacChatBenchHost) {
        self.host = host
    }

    static func tag(of text: String) -> Int? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        return Int(text[text.index(after: text.startIndex)..<close])
    }

    func sample() -> Sample {
        var current = Sample()
        if let scrollView = host.transcriptScrollView {
            current.offset = scrollView.contentView.bounds.origin.y
            current.document = scrollView.documentView?.frame.height ?? 0
        }
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, let tag = Self.tag(of: text.string) {
                current.rows[tag] = view.convert(view.bounds, to: host.view)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(host.view)
        return current
    }

    func step(_ frames: Int = 1) async throws {
        for _ in 0..<frames {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            frame += 1
            let current = sample()
            defer { previous = current }
            guard let previous, !muted else { continue }
            let viewport = CGRect(origin: .zero, size: host.view.bounds.size)
            for (row, rect) in current.rows {
                guard let before = previous.rows[row], viewport.intersects(rect), viewport.intersects(before) else { continue }
                let delta = rect.midY - before.midY
                if abs(delta) > 1 {
                    events.append(OpenJumpEvent(
                        frame: frame, phase: phase, row: row, delta: delta,
                        offsetDelta: current.offset - previous.offset, documentDelta: current.document - previous.document
                    ))
                }
            }
        }
    }

    var summary: String {
        let byPhase = Dictionary(grouping: events, by: \.phase)
        return byPhase.keys.sorted().map { phase in
            let list = byPhase[phase] ?? []
            let biggest = list.max { abs($0.delta) < abs($1.delta) }
            return "JUMP phase=\(phase) rowsMoved=\(list.count) largest=\(biggest.map(\.description) ?? "-")"
        }.joined(separator: "\n")
    }
}

enum OpenJumpFixture {
    private static let paragraphs = [
        "Short.",
        "I looked at the deploy log and the failure comes from the migration step. "
            + "The new column is declared non-null with no default, so it fails on every table that already has rows.",
        "The fix is to add the column as nullable, backfill it in batches, and only then add the constraint in a follow-up release. "
            + "That keeps the deploy safe to retry and avoids a long lock on the largest table. I have not changed anything yet. "
            + "Tell me if you want the migration split or if you would rather freeze writes for a few minutes and do it in one go.",
    ]

    static func text(_ index: Int) -> String {
        let body = paragraphs[index % paragraphs.count]
        guard index % 5 == 0 else { return "[\(index)] \(body)" }
        return "[\(index)] \(body)\n\n```swift\nlet value = \(index)\nprint(value)\n```\n\nAnd a closing line for \(index)."
    }

    static func world(_ range: Range<Int>, running: Bool = false) -> RebuildWorld {
        var world = RebuildWorld()
        world.isRunning = running
        world.rows.removeAll()
        for index in range {
            let item = rebuildAssistant("a\(index)", text(index), at: rebuildAt(Double(index) * 90))
            world.rows.append((UInt64(1_000 + index), item))
        }
        return world
    }
}

@MainActor
@Suite("Mac chat open jump", .serialized)
struct MacChatOpenJumpTests {
    private struct Opened {
        let model: ChatModel
        let host: MacChatBenchHost
        let probe: OpenJumpProbe
    }

    private static let live = ChatPhase.live(lastSequence: 1, replayEpoch: "e")

    private func open() async throws -> Opened {
        let environment = try MacChatBenchSession.environment()
        let host = MacChatBenchHost(
            root: environment.surface(draft: MacChatBenchDraft(), scroll: ChatScrollController()), size: MacChatBench.pane
        )
        try await Task.sleep(for: .milliseconds(20))
        let opened = Opened(model: environment.model, host: host, probe: OpenJumpProbe(host: host))
        opened.probe.phase = "cached"
        opened.model.apply(OpenJumpFixture.world(100..<160).snapshot(version: 10))
        try await opened.probe.step(60)
        return opened
    }

    private func readHistory(_ opened: Opened, points: Double = 1500) async throws {
        opened.probe.muted = true
        opened.host.liveScroll(NSScrollView.willStartLiveScrollNotification)
        for _ in 0..<Int(points / 50) {
            opened.host.scroll(by: 50)
            try await opened.probe.step()
        }
        opened.host.liveScroll(NSScrollView.didEndLiveScrollNotification)
        try await opened.probe.step(30)
        opened.probe.muted = false
        try await opened.probe.step(2)
    }

    private func expectStill(_ opened: Opened) {
        #expect(opened.probe.events.isEmpty, Comment(rawValue: opened.probe.summary))
    }

    @Test("at the newest edge a live snapshot that adds nothing and an older page keep the visible rows still")
    func newestEdgeStaysStill() async throws {
        let opened = try await open()
        defer { opened.host.close() }
        opened.probe.phase = "live-identical"
        opened.model.apply(OpenJumpFixture.world(100..<160).snapshot(version: 11))
        try await opened.probe.step(60)
        opened.probe.phase = "older-page"
        opened.model.apply(OpenJumpFixture.world(70..<160).snapshot(version: 12))
        try await opened.probe.step(60)
        expectStill(opened)
    }

    @Test("reading history, an older page and new tail rows keep the visible rows still")
    func readingKeepsStillForPagesAndTail() async throws {
        let opened = try await open()
        defer { opened.host.close() }
        try await readHistory(opened)
        opened.probe.phase = "older-page"
        opened.model.apply(OpenJumpFixture.world(70..<160).snapshot(version: 11))
        try await opened.probe.step(60)
        opened.probe.phase = "tail-rows"
        opened.model.apply(OpenJumpFixture.world(70..<163).snapshot(version: 12))
        try await opened.probe.step(60)
        expectStill(opened)
    }

    @Test("reading history, a working row that comes and goes keeps the visible rows still")
    func readingKeepsStillForWorkingRow() async throws {
        let opened = try await open()
        defer { opened.host.close() }
        try await readHistory(opened)
        opened.probe.phase = "working-row-appears"
        opened.model.apply(OpenJumpFixture.world(100..<160, running: true).snapshot(version: 11))
        try await opened.probe.step(60)
        opened.probe.phase = "working-row-goes"
        opened.model.apply(OpenJumpFixture.world(100..<160, running: false).snapshot(version: 12))
        try await opened.probe.step(60)
        expectStill(opened)
    }

    @Test("reading history, the catch-up line appearing and going when the chat connects keeps the visible rows still")
    func readingKeepsStillForCatchUpLine() async throws {
        let opened = try await open()
        defer { opened.host.close() }
        try await readHistory(opened)
        opened.probe.phase = "catch-up-line-appears"
        try await opened.probe.step(6 * 120)
        opened.probe.phase = "catch-up-line-goes"
        opened.model.applyPhase(Self.live)
        try await opened.probe.step(60)
        expectStill(opened)
    }
}
#endif
