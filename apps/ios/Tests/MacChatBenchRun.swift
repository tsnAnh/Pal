#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import HermesBots

enum MacChatBench {
    static let outputKey = "HERMES_MAC_BENCH_OUT"
    static let warmup = 10
    static let framePeriod: TimeInterval = 1.0 / 120.0
    static let openWindowFrames = 12
    nonisolated(unsafe) static let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "mac chat bench"
    )
    static let rounds = 3
    static let scrollRounds = 6
    static let settleFrames = 120
    static let openAttempts = 6
    static let pane = CGSize(width: 1000, height: 830)

    static var output: URL? {
        ProcessInfo.processInfo.environment[outputKey].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }
}

@MainActor
final class MacChatBenchSession {
    let model: ChatModel
    let draft = MacChatBenchDraft()
    let scroll = ChatScrollController()
    let host: MacChatBenchHost
    var world: RebuildWorld
    private var version: UInt64 = 1_000

    static func environment() throws -> MacChatBenchEnvironment {
        MacChatBenchEnvironment(model: try rebuildChatModel())
    }

    init(environment: MacChatBenchEnvironment, streamingTail: Bool, size: CGSize = MacChatBench.pane) {
        let initial = MacChatBenchFixture.world(streamingTail: streamingTail)
        model = environment.model
        world = initial
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: scroll), size: size)
        host.settle()
        model.apply(initial.snapshot(version: version))
        host.settle()
        scroll.jumpToBottom(animated: false)
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    func close() {
        host.close()
    }
}

@MainActor
final class MacChatBenchRun {
    private let clock = ContinuousClock()
    private let watchdog = MacChatBenchWatchdog.shared
    let directory: URL
    private var lastWall = 0.0
    private(set) var openFrames: [Int] = []
    private(set) var openRetries = 0

    init(directory: URL) {
        self.directory = directory
        _ = MacChatBench.activity
        watchdog.sampleTo = directory.appending(path: "watchdog-sample.txt")
    }

    func openSession(streamingTail: Bool) throws -> MacChatBenchSession {
        for _ in 0..<MacChatBench.openAttempts {
            watchdog.arm("open session")
            let session = MacChatBenchSession(environment: try MacChatBenchSession.environment(), streamingTail: streamingTail)
            let frames = session.host.settleAtNewest(maxFrames: MacChatBench.settleFrames)
            watchdog.disarm()
            if frames < MacChatBench.settleFrames { return session }
            session.close()
            openRetries += 1
        }
        throw MacChatBenchError.openNeverSettled
    }

    func pooled(rounds: Int, _ measure: () throws -> MacChatBenchScenario) throws -> MacChatBenchScenario {
        var cpu: [Double] = []
        var wall: [Double] = []
        var name = ""
        for _ in 0..<rounds {
            let round = try measure()
            name = round.name
            cpu += round.samples
            wall += round.wall
        }
        return MacChatBenchScenario(name: name, samples: cpu, wall: wall)
    }

    func record(_ scenario: MacChatBenchScenario) throws {
        let report = MacChatBenchReport(
            generated: ISO8601DateFormatter().string(from: Date()),
            paneWidth: MacChatBench.pane.width,
            paneHeight: MacChatBench.pane.height,
            transcriptMessages: MacChatBenchFixture.messageCount,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            openFrames: openFrames,
            openRetries: openRetries,
            scenarios: [scenario]
        )
        try report.write(to: directory, name: "scenario-\(scenario.name).json")
        print(report.table())
    }

    private func time(_ label: String, _ work: () -> Void) -> Double {
        watchdog.arm(label)
        defer { watchdog.disarm() }
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let elapsed = clock.measure(work)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
        lastWall = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return cpu
    }

    private func scenario(
        _ name: String, steps: Int, host: MacChatBenchHost, afterStep: (Int) throws -> Void = { _ in }, _ step: (Int) -> Void
    ) throws -> MacChatBenchScenario {
        for index in 0..<MacChatBench.warmup {
            _ = time("\(name) warmup \(index)") {
                step(index)
                host.settle()
            }
        }
        var cpu: [Double] = []
        var wall: [Double] = []
        for index in MacChatBench.warmup..<(MacChatBench.warmup + steps) {
            cpu.append(time("\(name) step \(index)") {
                step(index)
                host.settle()
            })
            wall.append(lastWall)
            try afterStep(index - MacChatBench.warmup)
        }
        try host.snapshot(to: directory.appending(path: "\(name)-end.png"))
        return MacChatBenchScenario(name: name, samples: cpu, wall: wall)
    }

    func chatOpenCold(repetitions: Int) throws -> MacChatBenchScenario {
        var cpu: [Double] = []
        var wall: [Double] = []
        for _ in 0..<repetitions {
            let environment = try MacChatBenchSession.environment()
            var session: MacChatBenchSession?
            cpu.append(time("chat-open-cold") {
                session = MacChatBenchSession(environment: environment, streamingTail: false)
                for _ in 0..<MacChatBench.openWindowFrames { session?.host.settle() }
            })
            wall.append(lastWall)
            openFrames.append(session?.host.settleAtNewest(maxFrames: MacChatBench.settleFrames) ?? 0)
            session?.close()
        }
        return MacChatBenchScenario(name: "chat-open-cold", samples: cpu, wall: wall)
    }

    func composerTyping(steps: Int) throws -> MacChatBenchScenario {
        let session = try openSession(streamingTail: false)
        defer { session.close() }
        let letters = Array("the quick brown fox jumps over the lazy dog ")
        return try scenario("composer-typing", steps: steps, host: session.host) { index in
            session.draft.text.append(letters[index % letters.count])
        }
    }

    func streaming(steps: Int) throws -> MacChatBenchScenario {
        let session = try openSession(streamingTail: true)
        defer { session.close() }
        var text = "Looking into it now."
        return try scenario("streaming", steps: steps, host: session.host) { index in
            text += MacChatBenchFixture.streamDelta(at: index)
            let grown = text
            session.world.editLast { $0.content = .assistant(text: grown, reasoning: "", isStreaming: true) }
            session.push()
        }
    }

    func historyScroll(steps: Int) throws -> MacChatBenchScenario {
        let session = try openSession(streamingTail: false)
        defer { session.close() }
        let travel = 60.0
        let half = steps / 2
        let turnaround = half - 1
        let mid = directory.appending(path: "history-scroll-oldest.png")
        let move: (Int) -> Void = { index in
            let leg = (index - MacChatBench.warmup + steps) % steps
            if index == 0 || leg == 0 || leg == half { session.host.liveScroll(NSScrollView.willStartLiveScrollNotification) }
            session.host.scroll(by: leg < half ? travel : -travel)
            if leg == half - 1 || leg == steps - 1 { session.host.liveScroll(NSScrollView.didEndLiveScrollNotification) }
        }
        let snapshotAtTurnaround: (Int) throws -> Void = { step in
            if step == turnaround { try session.host.snapshot(to: mid) }
        }
        return try scenario("history-scroll", steps: steps, host: session.host, afterStep: snapshotAtTurnaround, move)
    }

    func windowResize(steps: Int) throws -> MacChatBenchScenario {
        let session = try openSession(streamingTail: false)
        defer { session.close() }
        let sidebar = 280.0
        let low = 900.0
        let span = 500.0
        let half = Double(steps) / 2
        return try scenario("window-resize", steps: steps, host: session.host) { index in
            let phase = Double((index - MacChatBench.warmup + steps) % steps)
            let fraction = phase < half ? phase / half : 2 - phase / half
            session.host.resize(to: CGSize(width: low + span * fraction - sidebar, height: MacChatBench.pane.height))
        }
    }
}
#endif
