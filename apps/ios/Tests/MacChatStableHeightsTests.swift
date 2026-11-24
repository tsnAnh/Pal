#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

struct StableHeightSample {
    let phase: String
    let seconds: Double
    let sample: ChatScrollSample

    var changesContent: Bool { abs(sample.contentDelta) > ChatContentLedger.movedThreshold }
    var isIdle: Bool { !sample.userScrolling && sample.writer != .user }
    var unexplainedOffset: Double { sample.offsetDelta - sample.contentDelta }
}

struct StableHeightFacts {
    static let swingPoints = 2.0
    static let batchSeconds = 0.150
    static let batchTolerance = 0.025
    static let stepClusterSeconds = 0.040

    let samples: [StableHeightSample]

    private var afterFirstLayout: [StableHeightSample] {
        guard let first = samples.firstIndex(where: { $0.sample.geometry.contentHeight > $0.sample.geometry.containerHeight }) else { return [] }
        return Array(samples[(first + 1)...])
    }

    var idleSwings: [StableHeightSample] {
        afterFirstLayout.filter {
            $0.isIdle && [.systemAnchor, .unattributed].contains($0.sample.writer) && abs($0.unexplainedOffset) > Self.swingPoints
        }
    }

    var replacedEstimates: [StableHeightSample] {
        afterFirstLayout.filter { $0.sample.contentSource == .estimateReplaced }
    }

    func shrinks(in phase: String) -> [StableHeightSample] {
        samples.filter { $0.phase == phase && $0.sample.contentDelta < -ChatContentLedger.movedThreshold }
    }

    func stepTimes(in phase: String) -> [Double] {
        var times: [Double] = []
        for sample in samples where sample.phase == phase && sample.changesContent {
            if let last = times.last, sample.seconds - last < Self.stepClusterSeconds { continue }
            times.append(sample.seconds)
        }
        return times
    }

    func quickSteps(in phase: String) -> [Double] {
        let times = stepTimes(in: phase)
        return zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 < Self.batchSeconds - Self.batchTolerance }
    }

    func summary(_ items: [StableHeightSample]) -> String {
        let head = items.prefix(6).map {
            String(
                format: "t=%.3f [%@] offset %+.1f content %+.1f writer=%@ source=%@",
                $0.seconds, $0.phase, $0.sample.offsetDelta, $0.sample.contentDelta, $0.sample.writer.rawValue, $0.sample.contentSource.rawValue
            )
        }
        return "count=\(items.count)\n" + head.joined(separator: "\n")
    }
}

@MainActor
private final class StableHeightsStage {
    static let openFrames = 240
    static let tokens = 120
    static let framesPerToken = 3

    let model: ChatModel
    let host: MacChatBenchHost
    let draft = MacChatBenchDraft()
    let scroll = ChatScrollController()
    var world: RebuildWorld
    var phase = "open"
    private(set) var samples: [StableHeightSample] = []
    private let clock = ContinuousClock()
    private let start = ContinuousClock.now
    private var version: UInt64 = 10

    init(streaming: Bool) async throws {
        let environment = try MacChatBenchSession.environment()
        world = MacChatBenchFixture.world(streamingTail: streaming, messageCount: 156, images: true)
        model = environment.model
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: scroll), size: MacChatBench.pane)
        scroll.sampleSink = { [unowned self] in record($0) }
        try await Task.sleep(for: .milliseconds(20))
    }

    var facts: StableHeightFacts { StableHeightFacts(samples: samples) }

    private func record(_ sample: ChatScrollSample) {
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        samples.append(StableHeightSample(phase: phase, seconds: seconds, sample: sample))
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    func step(_ frames: Int) async throws {
        for _ in 0..<frames { try await Task.sleep(for: .seconds(MacChatBench.framePeriod)) }
    }

    func open() async throws {
        phase = "open"
        push()
        try await step(Self.openFrames)
    }

    func streamTurn() async throws {
        phase = "stream"
        var text = "Looking into it now."
        for index in 0..<Self.tokens {
            text += MacChatBenchFixture.streamDelta(at: index)
            let grown = text
            world.editLast { $0.content = .assistant(text: grown, reasoning: "", isStreaming: true) }
            if index == 40 || index == 80 {
                let tool = rebuildAnswered("call\(index)", index, "Proceed with the migration?", at: rebuildAt(30_000 + Double(index)))
                world.rows.insert((world.nextKey, tool), at: world.rows.count - 1)
                world.nextKey += 1
            }
            push()
            try await step(Self.framesPerToken)
        }
        phase = "stream-finishes"
        let finished = text
        world.editLast { $0.content = .assistant(text: finished, reasoning: "", isStreaming: false) }
        world.isRunning = false
        push()
        try await step(60)
    }

    func writeCSV(named name: String) {
        guard let directory = MacChatBench.output else { return }
        let header = "seconds,phase,offset_y,content_h,container_h,offset_delta,content_delta,content_source,writer"
        let rows = samples.map {
            String(
                format: "%.4f,%@,%.2f,%.2f,%.2f,%.2f,%.2f,%@,%@",
                $0.seconds, $0.phase, $0.sample.geometry.offsetY, $0.sample.geometry.contentHeight,
                $0.sample.geometry.containerHeight, $0.sample.offsetDelta, $0.sample.contentDelta,
                $0.sample.contentSource.rawValue, $0.sample.writer.rawValue
            )
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ([header] + rows).joined(separator: "\n").appending("\n").write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }
}

@MainActor
@Suite("Mac chat stable heights", .serialized, .enabled(if: MacChatBench.output != nil))
struct MacChatStableHeightsTests {
    @Test("opening a 156 row chat never swings the list and never replaces an estimate after the first layout")
    func openStaysStill() async throws {
        let stage = try await StableHeightsStage(streaming: false)
        defer { stage.host.close() }
        try await stage.open()
        stage.writeCSV(named: "stable-heights-open.csv")
        let facts = stage.facts
        #expect(!facts.samples.isEmpty, "the list never reported its geometry")
        #expect(facts.idleSwings.isEmpty, Comment(rawValue: "idle swings over \(StableHeightFacts.swingPoints) pt: " + facts.summary(facts.idleSwings)))
        #expect(
            facts.replacedEstimates.isEmpty,
            Comment(rawValue: "content height changed after the first layout without a new row: " + facts.summary(facts.replacedEstimates))
        )
    }

    @Test("a streaming turn with tool rows grows the list in batches, never shrinks it and never swings it")
    func streamingStaysStill() async throws {
        let stage = try await StableHeightsStage(streaming: true)
        defer { stage.host.close() }
        try await stage.open()
        try await stage.streamTurn()
        stage.writeCSV(named: "stable-heights-stream.csv")
        let facts = stage.facts
        let shrinks = facts.shrinks(in: "stream")
        let quick = facts.quickSteps(in: "stream")
        #expect(facts.idleSwings.isEmpty, Comment(rawValue: "idle swings over \(StableHeightFacts.swingPoints) pt: " + facts.summary(facts.idleSwings)))
        #expect(shrinks.isEmpty, Comment(rawValue: "content height shrank while streaming: " + facts.summary(shrinks)))
        #expect(
            quick.isEmpty,
            Comment(rawValue: "content height stepped faster than every \(StableHeightFacts.batchSeconds) s: gaps \(quick.prefix(8))")
        )
    }
}
#endif
