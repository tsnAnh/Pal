#if os(macOS)
import AppKit
import CoreGraphics
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat window resize", .serialized)
struct MacChatResizeTests {
    static let steps: [(name: String, size: CGSize)] = [
        ("narrow", CGSize(width: 640, height: 830)),
        ("wide", CGSize(width: 1500, height: 830)),
        ("full screen", CGSize(width: 1500, height: 1100)),
        ("back", CGSize(width: 1000, height: 830)),
    ]

    private func resize(_ stage: VisibleRowsStage, to size: CGSize) async throws {
        stage.resetStreaks()
        stage.host.resize(to: size)
        try await stage.step(90)
    }

    @Test("resizing the window in steps with a 150 row chat open never shows a blank pane and keeps the newest row at the bottom")
    func pinnedStaysPinned() async throws {
        let stage = try await VisibleRowsStage(opening: VisibleRowsStage.tallTailWorld(count: 150))
        defer { stage.host.close() }
        for step in Self.steps {
            try await resize(stage, to: step.size)
            let geometry = try #require(stage.lastGeometry)
            let line = "\(step.name): \(stage.summary), distance \(geometry.distanceFromBottom), past end \(geometry.overshoot)"
            print("RESIZE \(line), content \(geometry.contentHeight)")
            let context = Comment(rawValue: line)
            #expect(stage.longestBlankStreak <= VisibleRowsStage.framesAllowed, context)
            #expect(geometry.distanceFromBottom <= ChatScrollMachine.atBottomTolerance, context)
            #expect(geometry.overshoot <= 8, context)
        }
    }
}
#endif
