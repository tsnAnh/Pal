#if os(macOS)
import AppKit
import CoreGraphics
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat live width drag", .serialized)
struct MacChatWidthDragTests {
    static let stepCount = 60
    static let stepWidth = 6.0
    static let frameBudgetMilliseconds = 16.0
    static let firstStepBudgetMilliseconds = 50.0
    static let singleStallBudgetMilliseconds = 25.0
    static let contentChangeLimit = 0.02
    static let firstStepContentChangeLimit = 0.03
    static let linesOfDrift = 120.0

    struct Step {
        var width: Double
        var stallMilliseconds: Double
        var contentHeight: Double
        var contentChange: Double
        var rowBodies: Int
        var distanceFromNewest: Double
    }

    private func drag(_ stage: VisibleRowsStage, from startWidth: Double) async throws -> [Step] {
        ChatOpenMetrics.isOn = true
        let probe = MainStallProbe()
        probe.start()
        defer { probe.stop() }
        var steps: [Step] = []
        var previous = try #require(stage.lastGeometry).contentHeight
        for index in 1...Self.stepCount {
            let width = startWidth + Double(index) * Self.stepWidth
            let before = ChatOpenMetrics.snapshot.rowBodies
            let stalls = MainStallProbe()
            stalls.start()
            stage.host.resize(to: CGSize(width: width, height: 830))
            try await stage.step(1)
            stalls.stop()
            let content = try #require(stage.lastGeometry).contentHeight
            steps.append(Step(
                width: width, stallMilliseconds: stalls.longest.ms, contentHeight: content,
                contentChange: abs(content - previous) / max(previous, 1),
                rowBodies: ChatOpenMetrics.snapshot.rowBodies - before, distanceFromNewest: stage.distanceFromNewest
            ))
            previous = content
        }
        return steps
    }

    @Test(
        "dragging the sidebar edge across a 200 row chat keeps every frame under 16 ms, content steady and the newest row anchored",
        arguments: [1000.0, 560.0]
    )
    func liveDragOfALongChat(startWidth: Double) async throws {
        let stage = try await VisibleRowsStage(opening: VisibleRowsStage.tallTailWorld(count: 200))
        defer { stage.host.close() }
        stage.host.resize(to: CGSize(width: startWidth, height: 830))
        try await stage.step(60)
        stage.resetStreaks()
        let steps = try await drag(stage, from: startWidth)
        let rest = steps.dropFirst()
        let stalls = rest.map(\.stallMilliseconds).sorted()
        let worstStall = stalls.last ?? 0
        let ninetyFifth = stalls.isEmpty ? 0 : stalls[min(stalls.count - 1, Int(Double(stalls.count) * 0.95))]
        let worstChange = rest.map(\.contentChange).max() ?? 0
        let worstDrift = steps.map(\.distanceFromNewest).max() ?? 0
        let first = try #require(steps.first)
        try await stage.step(40)
        let summary = String(
            format: "first step %.1f ms and %.2f%%, then 95th percentile stall %.1f ms, worst stall %.1f ms, "
                + "worst content change %.2f%%, worst drift %.0f pt, settled at %.0f pt from the newest row, "
                + "most row bodies in a step %d, blank %d frames",
            first.stallMilliseconds, first.contentChange * 100, ninetyFifth, worstStall, worstChange * 100, worstDrift, stage.distanceFromNewest,
            steps.map(\.rowBodies).max() ?? 0, stage.longestBlankStreak
        )
        print("WIDTHDRAG from \(Int(startWidth)): \(summary) state \(stage.scroll.machine.state.name) machineDistance \(stage.scroll.machine.distanceFromBottom ?? -1)")
        for step in steps where ProcessInfo.processInfo.environment["PAL_WIDTHDRAG_ALL"] == "1" {
            print(String(
                format: "WIDTHDRAG step width %.0f stall %.1f ms content %.0f (%.2f%%) bodies %d distance %.0f",
                step.width, step.stallMilliseconds, step.contentHeight, step.contentChange * 100, step.rowBodies, step.distanceFromNewest
            ))
        }
        let context = Comment(rawValue: summary)
        #expect(first.stallMilliseconds <= Self.firstStepBudgetMilliseconds, context)
        #expect(first.contentChange <= Self.firstStepContentChangeLimit, context)
        #expect(ninetyFifth <= Self.frameBudgetMilliseconds, context)
        #expect(worstStall <= Self.singleStallBudgetMilliseconds, context)
        #expect(worstChange <= Self.contentChangeLimit, context)
        #expect(worstDrift <= Self.linesOfDrift, context)
        #expect(stage.distanceFromNewest <= ChatScrollMachine.atBottomTolerance, context)
        #expect(stage.longestBlankStreak <= VisibleRowsStage.framesAllowed, context)
    }
}
#endif
