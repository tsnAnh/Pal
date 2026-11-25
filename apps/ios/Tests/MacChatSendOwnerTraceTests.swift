#if os(macOS)
import Foundation
import PalChat
import Testing

@testable import Pal

@MainActor
@Suite("Mac chat send owner trace", .serialized)
struct MacChatSendOwnerTraceTests {
    static let rowCount = 34
    static let sentences = 54
    static let checkpointFrames = [12, 60, 120, 240, 360]
    static let replyGrowthFrame = 40
    static let observedFrames = 400
    static let unreportedGrowth = 5.0

    static func isUnownedWrite(_ frame: SendStressFrame) -> Bool {
        frame.writers.contains(ChatScrollWriter.unattributed.rawValue) && abs(frame.contentDelta) <= ChatScrollMachine.atBottomTolerance
    }

    static func world() -> RebuildWorld {
        var world = RebuildWorld()
        world.isRunning = false
        world.rows.removeAll()
        let sentence = "The scheduler picks the next job by priority, then by age, then by owner, and skips any job whose dependencies are not done. "
        for index in 0..<rowCount {
            let body = "[\(index)] " + String(repeating: sentence, count: sentences + index % 5)
            world.rows.append((UInt64(1_000 + index), rebuildAssistant("a\(index)", body, at: rebuildAt(Double(index) * 90))))
        }
        world.nextKey = 2_000
        return world
    }

    @Test("a send in a 34 row chat of 54k points ends at the bottom at 100 ms, 500 ms, 1 s, 2 s and 3 s with no write nobody owns")
    func sendInAnOwnerSizedChat() async throws {
        let stage = try await SendStressStage(opening: Self.world())
        defer { stage.host.close() }
        stage.phase = "compose"
        stage.draft.text = "one line draft"
        try await stage.step(60)
        let start = stage.frames.count
        let content = stage.frames.last?.content ?? 0
        stage.phase = "send"
        stage.world.append(rebuildUser("u0", "message 0", delivery: .sending, at: rebuildAt(20_000)))
        stage.world.isRunning = true
        stage.push()
        stage.draft.text = ""
        stage.scroll.sent(animated: true)
        try await stage.step(Self.replyGrowthFrame)
        stage.phase = "stream"
        stage.world.append(rebuildAssistant("s0", "[1000] Looking into it now.", streaming: true, at: rebuildAt(20_005)))
        stage.push()
        try await stage.step(Self.observedFrames - Self.replyGrowthFrame)
        let after = Array(stage.frames[start...])
        let checkpoints = Self.checkpointFrames.map { after[$0 - 1] }
        let report = checkpoints.map { "#\($0.index) d=\(String(format: "%.1f", $0.distance)) machine=\(String(format: "%.1f", $0.machineDistance)) state \($0.state)" }
        let unowned = after.filter(Self.isUnownedWrite)
        print("SENDOWNER content=\(Int(content)) \(report) unattributedFrames=\(after.filter { $0.writers.contains(ChatScrollWriter.unattributed.rawValue) }.map(\.index)) unownedWrites=\(unowned.map(\.index)) maxDistance=\(after.map(\.distance).max() ?? 0)")
        for checkpoint in checkpoints {
            #expect(checkpoint.distance <= Self.unreportedGrowth, Comment(rawValue: "\(report)"))
            #expect(checkpoint.machineDistance <= ChatScrollMachine.atBottomTolerance, Comment(rawValue: "\(report)"))
            #expect(checkpoint.state == "pinnedToBottom" && !checkpoint.button, Comment(rawValue: "\(report)"))
        }
        let detail = unowned.map { "#\($0.index) \($0.phase) offset \(String(format: "%+.1f", $0.offsetDelta)) content \(String(format: "%+.1f", $0.contentDelta)) d=\(String(format: "%.1f", $0.distance))" }
        #expect(unowned.isEmpty, Comment(rawValue: "writes attributed unattributed: \(detail)"))
        #expect(stage.scroll.pinnedButShortCount == 0, Comment(rawValue: "pinned_but_short episodes: \(stage.scroll.pinnedButShortCount)"))
    }

    static let sends = 20
    static let framesPerSend = 300
    static let stressCheckpoints = [12, 60, 240]

    @Test("20 sends in a 34 row chat end at the bottom at 100 ms, 500 ms and 2 s with no write nobody owns")
    func twentySends() async throws {
        let stage = try await SendStressStage(opening: Self.world())
        defer { stage.host.close() }
        var misses: [String] = []
        var worst = 0.0
        for round in 0..<Self.sends {
            let start = stage.frames.count
            stage.phase = "send"
            stage.world.append(rebuildUser("u\(round)", "message \(round)", delivery: .sending, at: rebuildAt(20_000 + Double(round) * 10)))
            stage.world.isRunning = true
            stage.push()
            stage.scroll.sent(animated: true)
            try await stage.step(Self.replyGrowthFrame)
            stage.phase = "stream"
            stage.world.append(rebuildAssistant("s\(round)", "[\(1_000 + round)] Looking into it now.", streaming: true, at: rebuildAt(20_005 + Double(round) * 10)))
            stage.confirmSend(round)
            stage.push()
            try await stage.step(80)
            stage.world.editLast { $0.content = .assistant(text: "[\(1_000 + round)] Looking into it now. Done.", reasoning: "", isStreaming: false) }
            stage.world.isRunning = false
            stage.push()
            try await stage.step(Self.framesPerSend - Self.replyGrowthFrame - 80)
            let after = Array(stage.frames[start...])
            let distances = Self.stressCheckpoints.map { after[$0 - 1].distance }
            worst = max(worst, distances.max() ?? 0)
            if distances.contains(where: { $0 > Self.unreportedGrowth }) {
                misses.append("send \(round): " + distances.map { String(format: "%.1f", $0) }.joined(separator: "/"))
            }
            let unowned = after.filter(Self.isUnownedWrite).map(\.index)
            if !unowned.isEmpty { misses.append("send \(round): unattributed at \(unowned)") }
        }
        let allUnattributed = stage.frames.filter { $0.writers.contains(ChatScrollWriter.unattributed.rawValue) }.count
        let short = stage.scroll.pinnedButShortCount
        print("SENDTWENTY pinnedButShort=\(short) worst=\(String(format: "%.1f", worst)) unattributedFrames=\(allUnattributed) misses=\(misses)")
        #expect(misses.isEmpty, Comment(rawValue: "\(misses)"))
        #expect(stage.scroll.pinnedButShortCount == 0, Comment(rawValue: "pinned_but_short episodes: \(stage.scroll.pinnedButShortCount)"))
    }
}
#endif
