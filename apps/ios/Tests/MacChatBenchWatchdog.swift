#if os(macOS)
import Foundation
import Synchronization

final class MacChatBenchWatchdog: Sendable {
    private struct State {
        var label = "idle"
        var deadline = Date.distantFuture
        var sampleTo = URL(filePath: "/tmp/bench-watchdog-sample.txt")
    }

    static let shared = MacChatBenchWatchdog()
    static let stepBudget: TimeInterval = 20

    private let state = Mutex(State())

    var sampleTo: URL {
        get { state.withLock { $0.sampleTo } }
        set { state.withLock { $0.sampleTo = newValue } }
    }

    private init() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                let snapshot = state.withLock { $0 }
                guard Date() > snapshot.deadline else { continue }
                let sampler = Process()
                sampler.executableURL = URL(filePath: "/usr/bin/sample")
                sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", snapshot.sampleTo.path]
                try? sampler.run()
                sampler.waitUntilExit()
                FileHandle.standardError.write(Data("bench watchdog: \(snapshot.label) exceeded \(Self.stepBudget)s on the main thread, aborting\n".utf8))
                exit(3)
            }
        }
        thread.start()
    }

    func arm(_ label: String) {
        state.withLock {
            $0.label = label
            $0.deadline = Date().addingTimeInterval(Self.stepBudget)
        }
    }

    func disarm() {
        state.withLock { $0.deadline = .distantFuture }
    }
}
#endif
