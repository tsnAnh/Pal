#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

@MainActor
private final class ScrollStressStage {
    let model: ChatModel
    let host: MacChatBenchHost
    let probe: OpenJumpProbe
    let draft: MacChatBenchDraft
    var world: RebuildWorld
    private var version: UInt64 = 10

    init(streaming: Bool) async throws {
        let environment = try MacChatBenchSession.environment()
        let draft = MacChatBenchDraft()
        var world = OpenJumpFixture.world(100..<160, running: streaming)
        if streaming {
            world.rows.append((UInt64(1_160), rebuildAssistant("a-stream", "[160] Looking into it now.", streaming: true, at: rebuildAt(160 * 90))))
        }
        self.draft = draft
        self.world = world
        model = environment.model
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: ChatScrollController()), size: MacChatBench.pane)
        probe = OpenJumpProbe(host: host)
        try await Task.sleep(for: .milliseconds(20))
        probe.phase = "open"
        model.apply(world.snapshot(version: version))
        try await probe.step(60)
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    func readHistory(points: Double = 1500) async throws {
        probe.muted = true
        host.liveScroll(NSScrollView.willStartLiveScrollNotification)
        for _ in 0..<Int(points / 50) {
            host.scroll(by: 50)
            try await probe.step()
        }
        host.liveScroll(NSScrollView.didEndLiveScrollNotification)
        try await probe.step(30)
        probe.muted = false
        try await probe.step(2)
    }
}

@MainActor
@Suite("Mac chat scroll stress (trace only)", .serialized)
struct MacChatScrollStressTests {
    @Test("reading history while the newest reply streams and then finishes keeps the visible rows still")
    func streamingWhileReading() async throws {
        let stage = try await ScrollStressStage(streaming: true)
        defer { stage.host.close() }
        try await stage.readHistory()
        stage.probe.phase = "stream-while-reading"
        var text = "[160] Looking into it now."
        for index in 0..<120 {
            text += MacChatBenchFixture.streamDelta(at: index)
            let grown = text
            stage.world.editLast { $0.content = .assistant(text: grown, reasoning: "", isStreaming: true) }
            stage.push()
            try await stage.probe.step()
        }
        stage.probe.phase = "stream-finishes"
        let finished = text
        stage.world.editLast { $0.content = .assistant(text: finished, reasoning: "", isStreaming: false) }
        stage.world.isRunning = false
        stage.push()
        try await stage.probe.step(60)
        #expect(stage.probe.events.isEmpty, Comment(rawValue: stage.probe.summary))
    }

    @Test("reading history while the composer grows to eight lines and shrinks keeps the visible rows still")
    func composerGrowsWhileReading() async throws {
        let stage = try await ScrollStressStage(streaming: false)
        defer { stage.host.close() }
        try await stage.readHistory()
        stage.probe.phase = "composer-grows"
        for lines in 1...8 {
            stage.draft.text = Array(repeating: "draft line", count: lines).joined(separator: "\n")
            try await stage.probe.step(6)
        }
        stage.probe.phase = "composer-shrinks"
        stage.draft.text = ""
        try await stage.probe.step(60)
        #expect(stage.probe.events.isEmpty, Comment(rawValue: stage.probe.summary))
    }
}
#endif
