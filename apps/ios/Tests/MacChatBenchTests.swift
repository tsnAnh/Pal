#if os(macOS)
import Foundation
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat bench", .serialized, .enabled(if: MacChatBench.output != nil))
struct MacChatBenchTests {
    private func makeRun() throws -> MacChatBenchRun {
        let directory = try #require(MacChatBench.output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MacChatBenchRun(directory: directory)
    }

    private func record(_ measure: (MacChatBenchRun) throws -> MacChatBenchScenario) throws {
        let run = try makeRun()
        try run.record(try measure(run))
    }

    @Test("the real chat views lay out and draw")
    func rendersTheRealViews() throws {
        let run = try makeRun()
        let session = try run.openSession(streamingTail: false)
        defer { session.close() }
        let scrollView = try #require(session.host.transcriptScrollView)
        let document = scrollView.documentView?.frame.height ?? 0
        try session.host.snapshot(to: run.directory.appending(path: "chat-open.png"))
        print("bench host: \(session.host.occlusion), descendants \(session.host.descendantCount()), transcript document height \(document)")
        #expect(document > MacChatBench.pane.height)
        #expect(session.host.isAtNewest)
    }

    @Test("chat-open-cold") func chatOpenCold() throws { try record { try $0.chatOpenCold(repetitions: 20) } }
    @Test("composer-typing") func composerTyping() throws {
        try record { run in try run.pooled(rounds: MacChatBench.rounds) { try run.composerTyping(steps: 150) } }
    }
    @Test("streaming") func streaming() throws {
        try record { run in try run.pooled(rounds: MacChatBench.rounds) { try run.streaming(steps: 200) } }
    }
    @Test("history-scroll") func historyScroll() throws {
        try record { run in try run.pooled(rounds: MacChatBench.scrollRounds) { try run.historyScroll(steps: 200) } }
    }
    @Test("window-resize") func windowResize() throws {
        try record { run in try run.pooled(rounds: MacChatBench.rounds) { try run.windowResize(steps: 100) } }
    }
}
#endif
