#if os(macOS)
import Foundation
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat send working row", .serialized)
struct MacChatSendWorkingRowTests {
    static let checkpointFrames = [12, 42, 60, 240, 600]
    static let workingRowFrame = 30
    static let composerLines = 8

    @Test("after a send the working row stays above the composer at 100 ms, 500 ms, 2 s and 5 s")
    func workingRowStaysAboveTheComposer() async throws {
        let stage = try await SendStressStage()
        defer { stage.host.close() }
        stage.phase = "compose"
        stage.draft.text = Array(repeating: "draft line", count: Self.composerLines).joined(separator: "\n")
        try await stage.step(60)
        let start = stage.frames.count
        stage.phase = "send"
        stage.world.append(rebuildUser("u0", "message 0", delivery: .sending, at: rebuildAt(20_000)))
        stage.push()
        stage.draft.text = ""
        stage.scroll.sent(animated: true)
        try await stage.step(Self.workingRowFrame)
        stage.world.isRunning = true
        stage.push()
        try await stage.step((Self.checkpointFrames.last ?? 0) - Self.workingRowFrame)
        let after = Array(stage.frames[start...])
        let checkpoints = Self.checkpointFrames.map { after[$0 - 1] }
        let report = checkpoints.map {
            "#\($0.index) d=\(String(format: "%.1f", $0.distance)) machine=\(String(format: "%.1f", $0.machineDistance)) button \($0.button) state \($0.state)"
        }
        let unattributed = after.filter { $0.writers.contains(ChatScrollWriter.unattributed.rawValue) }
        print("SENDWORKING \(report) unattributed=\(unattributed.count) maxDistance=\(after.map(\.distance).max() ?? 0)")
        for checkpoint in checkpoints {
            #expect(checkpoint.distance <= ChatScrollMachine.atBottomTolerance, Comment(rawValue: "\(report)"))
            #expect(checkpoint.machineDistance <= ChatScrollMachine.atBottomTolerance, Comment(rawValue: "\(report)"))
            #expect(!checkpoint.button, Comment(rawValue: "\(report)"))
        }
    }
}
#endif
