@testable import PalChat
import Foundation
import Synchronization
import Testing

private actor FrameGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var parkedWaiter: CheckedContinuation<Void, Never>?
    private var isParked = false

    func park() async {
        isParked = true
        parkedWaiter?.resume()
        parkedWaiter = nil
        await withCheckedContinuation { parked = $0 }
    }

    func untilParked() async {
        if isParked { return }
        await withCheckedContinuation { parkedWaiter = $0 }
    }

    func release() {
        isParked = false
        parked?.resume()
        parked = nil
    }
}

private final class AppliedLog: Sendable {
    private let snapshots = Mutex<[TimelineSnapshot]>([])
    func record(_ snapshot: TimelineSnapshot) { snapshots.withLock { $0.append(snapshot) } }
    var all: [TimelineSnapshot] { snapshots.withLock { $0 } }
}

private func snapshot(_ version: UInt64, text: String = "") -> TimelineSnapshot {
    TimelineSnapshot(
        version: version,
        sessionID: "s",
        rows: [],
        older: .start,
        isRunning: true,
        pendingPrompts: [],
        hasPendingConnection: false,
        lastError: nil,
        executionGeneration: 0,
        runningToolName: nil,
        streamingText: text
    )
}

@Suite("Timeline pacer", .serialized)
struct TimelinePacerTests {
    private struct Rig {
        let source: AsyncStream<TimelineSnapshot>.Continuation
        let gate: FrameGate
        let log: AppliedLog
        let consumer: Task<Void, Never>
    }

    private func start() -> Rig {
        let (stream, source) = AsyncStream.makeStream(of: TimelineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let gate = FrameGate()
        let log = AppliedLog()
        let consumer = Task {
            await TimelinePacer.consume(stream, pause: { await gate.park() }, apply: { log.record($0) })
        }
        return Rig(source: source, gate: gate, log: log, consumer: consumer)
    }

    @Test func manySnapshotsInOneFrameApplyOnceAndTheFinalStateMatches() async {
        let rig = start()
        let source = rig.source, gate = rig.gate, log = rig.log, consumer = rig.consumer
        source.yield(snapshot(1, text: "a"))
        await gate.untilParked()
        #expect(log.all.map(\.version) == [1])

        for version in 2...51 { source.yield(snapshot(UInt64(version), text: String(repeating: "a", count: version))) }
        await gate.release()
        await gate.untilParked()

        #expect(log.all.map(\.version) == [1, 51])
        #expect(log.all.last == snapshot(51, text: String(repeating: "a", count: 51)))

        source.finish()
        await gate.release()
        await consumer.value
        #expect(log.all.count == 2)
    }

    @Test func aSnapshotAfterAQuietFrameAppliesWithoutWaiting() async {
        let rig = start()
        let source = rig.source, gate = rig.gate, log = rig.log, consumer = rig.consumer
        source.yield(snapshot(1))
        await gate.untilParked()
        await gate.release()

        source.yield(snapshot(2))
        await gate.untilParked()
        #expect(log.all.map(\.version) == [1, 2])

        source.finish()
        await gate.release()
        await consumer.value
    }

    @Test func everyFrameBudgetAppliesAtMostOneSnapshot() async {
        let rig = start()
        let source = rig.source, gate = rig.gate, log = rig.log, consumer = rig.consumer
        source.yield(snapshot(1))
        await gate.untilParked()
        var version: UInt64 = 1
        for _ in 0..<5 {
            for _ in 0..<20 {
                version += 1
                source.yield(snapshot(version))
            }
            await gate.release()
            await gate.untilParked()
        }
        #expect(log.all.count == 6)
        #expect(log.all.last?.version == version)

        source.finish()
        await gate.release()
        await consumer.value
    }
}
