#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat scroll livelock", .serialized)
struct MacChatScrollLivelockTests {
    private static let sessions = 4
    private static let rounds = 150
    private static let shortPane = CGSize(width: 900, height: 520)

    @Test("a composer that grows in a short pane while the chat chases the newest edge never stalls the main thread")
    func growingComposerWhileChasingTheNewestEdge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mac-chat-scroll-livelock", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let run = MacChatBenchRun(directory: directory)
        let watchdog = MacChatBenchWatchdog.shared
        for _ in 0..<Self.sessions {
            let session = try run.openSession(streamingTail: false)
            defer { session.close() }
            var generator = RebuildSplitMix(state: 99)
            session.host.resize(to: Self.shortPane)
            for _ in 0..<10 { session.host.settle() }
            for round in 0..<Self.rounds {
                watchdog.arm("composer growth round \(round)")
                session.host.liveScroll(NSScrollView.willStartLiveScrollNotification)
                session.host.scroll(by: Double(100 + generator.next() % 900))
                session.host.liveScroll(NSScrollView.didEndLiveScrollNotification)
                for _ in 0..<Int(generator.next() % 3) { session.host.settle() }
                session.scroll.jumpToBottom(animated: false)
                let lines = 1 + Int(generator.next() % 9)
                session.draft.text = Array(repeating: "draft line", count: lines).joined(separator: "\n")
                for _ in 0..<Int(generator.next() % 4) { session.host.settle() }
                watchdog.disarm()
            }
            #expect(session.host.settleAtNewest(maxFrames: MacChatBench.settleFrames) < MacChatBench.settleFrames)
        }
    }
}
#endif
