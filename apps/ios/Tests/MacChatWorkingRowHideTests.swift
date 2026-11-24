#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat working row hide", .serialized, .enabled(if: MacChatBench.output != nil))
struct MacChatWorkingRowHideTests {
    private static let newestTag = 159

    private struct Frame {
        let index: Int
        let document: CGFloat
        let newestInDocument: CGFloat?
    }

    @Test("the working row collapses over several frames and the newest message stays put in the document")
    func rowCollapsesWithoutMovingTheNewestMessage() async throws {
        let environment = try MacChatBenchSession.environment()
        let host = MacChatBenchHost(
            root: environment.surface(draft: MacChatBenchDraft(), scroll: ChatScrollController()), size: MacChatBench.pane
        )
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(20))
        let probe = OpenJumpProbe(host: host)
        environment.model.apply(OpenJumpFixture.world(100..<160, running: true).snapshot(version: 10))
        host.settleAtNewest(maxFrames: 240)

        func frame(_ index: Int) -> Frame {
            let sample = probe.sample()
            return Frame(
                index: index, document: sample.document, newestInDocument: sample.rows[Self.newestTag].map { $0.minY + sample.offset }
            )
        }

        let before = frame(0)
        environment.model.apply(OpenJumpFixture.world(100..<160, running: false).snapshot(version: 11))
        var frames: [Frame] = []
        for index in 1...60 {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            frames.append(frame(index))
        }

        let after = try #require(frames.last)
        #expect(after.document < before.document - 1, "the row left and the content shrank")
        let inBetween = frames.filter { $0.document < before.document - 1 && $0.document > after.document + 1 }
        #expect(inBetween.count >= 3, "the collapse spans \(inBetween.count) frames, not one")
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.document <= $0.document + 0.5 }, "the content only shrinks")
        let anchor = try #require(before.newestInDocument)
        for frame in frames {
            guard let position = frame.newestInDocument else { continue }
            #expect(abs(position - anchor) <= 1, "newest message moved \(position - anchor) pt in the document at frame \(frame.index)")
        }
    }
}
#endif
