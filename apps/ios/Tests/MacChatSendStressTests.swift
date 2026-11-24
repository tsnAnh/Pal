#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

struct SendStressFrame {
    let index: Int
    let phase: String
    let offset: Double
    let distance: Double
    let content: Double
    let pastTheEnd: Double
    let state: String
    let button: Bool
    let writers: [String]
    let offsetDelta: Double
    let distanceDelta: Double
    let contentDelta: Double

    var isPinned: Bool { state == "pinnedToBottom" }

    var csv: String {
        let fields = [
            String(index), phase, String(format: "%.2f", offset), String(format: "%.2f", distance), String(format: "%.2f", content),
            String(format: "%+.2f", offsetDelta), String(format: "%+.2f", distanceDelta), state, button ? "1" : "0",
            writers.joined(separator: "|"),
        ]
        return fields.joined(separator: ",")
    }

    static let header = "frame,phase,offset_y,distance,content_h,offset_delta,distance_delta,state,button,writers"
}

struct SendStressSample {
    let offset: Double
    let distance: Double
    let content: Double
    let pastTheEnd: Double
}

@MainActor
private final class SendStressStage {
    static let rounds = 6
    static let streamFrames = 40
    static let swingLimit = 20.0
    static let sendGrowthLimit = 400.0

    let model: ChatModel
    let host: MacChatBenchHost
    let draft = MacChatBenchDraft()
    let scroll = ChatScrollController()
    var world: RebuildWorld = {
        var world = OpenJumpFixture.world(100..<160)
        world.nextKey = 2_000
        return world
    }()
    var phase = "open"
    private(set) var frames: [SendStressFrame] = []
    private(set) var roundEnds: [SendStressFrame] = []
    private var samples: [ChatScrollSample] = []
    private var version: UInt64 = 10
    private var previous: SendStressSample?

    init() async throws {
        let environment = try MacChatBenchSession.environment()
        model = environment.model
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: scroll), size: MacChatBench.pane)
        scroll.sampleSink = { [unowned self] in samples.append($0) }
        try await Task.sleep(for: .milliseconds(20))
        model.apply(world.snapshot(version: version))
        try await step(30)
        host.settleAtNewest(maxFrames: 240)
        previous = nil
        try await step(10)
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    private func measure() -> SendStressSample? {
        guard let scrollView = host.transcriptScrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let offset = Double(clip.bounds.origin.y)
        let newest = Double(document.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        return SendStressSample(offset: offset, distance: max(0, newest - offset), content: Double(document.frame.height), pastTheEnd: max(0, offset - newest))
    }

    func step(_ count: Int = 1) async throws {
        for _ in 0..<count {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            guard let now = measure() else { throw MacChatBenchError.noTranscriptScrollView }
            let writers = samples.map(\.writer.rawValue).filter { $0 != ChatScrollWriter.none.rawValue }
            samples.removeAll(keepingCapacity: true)
            frames.append(SendStressFrame(
                index: frames.count, phase: phase, offset: now.offset, distance: now.distance,
                content: now.content, pastTheEnd: now.pastTheEnd,
                state: scroll.machine.state.name, button: scroll.showsJumpButton, writers: writers,
                offsetDelta: previous.map { now.offset - $0.offset } ?? 0,
                distanceDelta: previous.map { now.distance - $0.distance } ?? 0,
                contentDelta: previous.map { now.content - $0.content } ?? 0
            ))
            previous = now
        }
    }

    func send(_ round: Int) async throws {
        phase = "send"
        world.append(rebuildUser("u\(round)", "message \(round)", delivery: .sending, at: rebuildAt(20_000 + Double(round) * 10)))
        world.isRunning = true
        push()
        draft.text = ""
        scroll.sent(animated: true)
        try await step(8)
    }

    func confirmSend(_ round: Int) {
        guard let index = world.rows.lastIndex(where: { $0.item.id == "u\(round)" }) else { return }
        world.rows[index].item = rebuildUser("u\(round)", "message \(round)", delivery: .sent, at: rebuildAt(20_000 + Double(round) * 10))
    }

    func streamReply(_ round: Int) async throws {
        phase = "stream-and-compose"
        var text = "[\(1_000 + round)] Looking into it now."
        world.append(rebuildAssistant("s\(round)", text, streaming: true, at: rebuildAt(20_005 + Double(round) * 10)))
        push()
        for index in 0..<Self.streamFrames {
            text += MacChatBenchFixture.streamDelta(at: index)
            let grown = text
            world.editLast { $0.content = .assistant(text: grown, reasoning: "", isStreaming: true) }
            if index == 10 { confirmSend(round) }
            draft.text = Array(repeating: "draft line", count: 1 + index * 7 / Self.streamFrames).joined(separator: "\n")
            push()
            try await step()
        }
        phase = "stream-finishes"
        let finished = text
        world.editLast { $0.content = .assistant(text: finished, reasoning: "", isStreaming: false) }
        world.isRunning = false
        push()
        try await step(20)
        if let end = frames.last { roundEnds.append(end) }
    }

    func expectNoBounce() {
        let swings = frames.filter { $0.phase != "open" && abs($0.offsetDelta) > Self.swingLimit }
        let growth = frames.filter { $0.phase == "send" && $0.contentDelta > Self.sendGrowthLimit }
        let past = frames.filter { $0.pastTheEnd > ChatScrollMachine.atBottomTolerance }
        let report = "swings=\(swings.map(\.index)) growth=\(growth.map(\.index)) pastTheEnd=\(past.map(\.index))"
        #expect(swings.isEmpty, Comment(rawValue: "offset swing over \(Self.swingLimit) pt in one frame: \(report)"))
        #expect(growth.isEmpty, Comment(rawValue: "content grew over \(Self.sendGrowthLimit) pt in one frame at a send: \(report)"))
        #expect(past.isEmpty, Comment(rawValue: "the viewport sat past the end of the content: \(report)"))
    }

    func writeCSV() {
        guard let directory = MacChatBench.output else { return }
        let body = ([SendStressFrame.header] + frames.map(\.csv)).joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: directory.appending(path: "send-stress-frames.csv"), atomically: true, encoding: .utf8)
    }
}

@MainActor
@Suite("Mac chat send stress", .serialized, .enabled(if: MacChatBench.output != nil))
struct MacChatSendStressTests {
    @Test("sending while the bot streams and the composer grows keeps the pinned list still and the jump button hidden")
    func pinnedSendStream() async throws {
        let stage = try await SendStressStage()
        defer { stage.host.close() }
        for round in 0..<SendStressStage.rounds {
            try await stage.send(round)
            try await stage.streamReply(round)
        }
        stage.phase = "composer-shrinks"
        stage.draft.text = ""
        try await stage.step(30)
        stage.writeCSV()
        stage.expectNoBounce()

        let frames = stage.frames
        let jumps = zip(frames, frames.dropFirst()).filter { before, after in
            before.isPinned && after.isPinned && abs(after.distanceDelta) > 1
        }.map { $0.1 }
        let buttonAtBottom = frames.filter { $0.button && $0.distance <= ChatScrollMachine.hideDistance }
        let buttonWhilePinned = frames.filter { $0.button && $0.isPinned && $0.distance <= ChatScrollMachine.showDistance }
        let writers = Dictionary(grouping: frames.flatMap(\.writers), by: { $0 }).mapValues(\.count)
        let report = """
        frames=\(frames.count) pinnedJumps=\(jumps.count) buttonAtBottom=\(buttonAtBottom.count) \
        buttonWhilePinned=\(buttonWhilePinned.count) writers=\(writers)
        first jumps: \(jumps.prefix(5).map { "frame \($0.index) [\($0.phase)] distance \($0.distanceDelta) writers \($0.writers)" })
        """
        #expect(jumps.isEmpty, Comment(rawValue: report))
        #expect(buttonAtBottom.isEmpty, Comment(rawValue: report))
        #expect(buttonWhilePinned.isEmpty, Comment(rawValue: report))
        let displaced = stage.roundEnds.filter { $0.distance > ChatScrollMachine.atBottomTolerance || $0.button }
        let displacedReport = displaced.map { "frame \($0.index) distance \($0.distance) button \($0.button)" }
        #expect(displaced.isEmpty, Comment(rawValue: "a send round ended away from the newest row: \(displacedReport)"))
    }
}
#endif
