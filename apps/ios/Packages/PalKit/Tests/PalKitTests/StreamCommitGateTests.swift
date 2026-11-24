import PalChat
import Testing

@Suite("Stream commit gate")
struct StreamCommitGateTests {
    private let start = ContinuousClock.now

    @Test func theFirstChunkShowsAtOnce() {
        var gate = StreamCommitGate()
        #expect(gate.offer(at: start, final: false) == .commitNow)
    }

    @Test func chunksInsideTheIntervalWaitForTheRestOfIt() {
        var gate = StreamCommitGate()
        _ = gate.offer(at: start, final: false)
        #expect(gate.offer(at: start.advanced(by: .milliseconds(40)), final: false) == .wait(.milliseconds(110)))
        #expect(gate.offer(at: start.advanced(by: .milliseconds(149)), final: false) == .wait(.milliseconds(1)))
        #expect(gate.offer(at: start.advanced(by: .milliseconds(150)), final: false) == .commitNow)
    }

    @Test func theFinalChunkAndTheEndOfTheTurnNeverWait() {
        var gate = StreamCommitGate()
        _ = gate.offer(at: start, final: false)
        #expect(gate.offer(at: start.advanced(by: .milliseconds(5)), final: true) == .commitNow)
        #expect(gate.offer(at: start.advanced(by: .milliseconds(10)), final: false) == .wait(.milliseconds(145)))
    }

    @Test func aDeferredFlushRestartsTheInterval() {
        var gate = StreamCommitGate()
        _ = gate.offer(at: start, final: false)
        gate.committed(at: start.advanced(by: .milliseconds(150)))
        #expect(gate.offer(at: start.advanced(by: .milliseconds(200)), final: false) == .wait(.milliseconds(100)))
    }

    @Test func aResetShowsTheNextChunkAtOnce() {
        var gate = StreamCommitGate()
        _ = gate.offer(at: start, final: false)
        gate.reset()
        #expect(gate.offer(at: start.advanced(by: .milliseconds(1)), final: false) == .commitNow)
    }

    @Test func aZeroIntervalNeverWaits() {
        var gate = StreamCommitGate(interval: .zero)
        _ = gate.offer(at: start, final: false)
        #expect(gate.offer(at: start, final: false) == .commitNow)
    }
}

@Suite("Streaming height reserve")
struct StreamingHeightReserveTests {
    private let line = 22.0

    @Test func growthIsReservedInWholeLines() {
        #expect(StreamingHeightReserve.reserved(measured: 22, current: 0, line: line) == 22)
        #expect(StreamingHeightReserve.reserved(measured: 30, current: 22, line: line) == 44)
        #expect(StreamingHeightReserve.reserved(measured: 44.4, current: 22, line: line) == 44)
    }

    @Test func aReservedHeightIsAFixedPointSoLayoutRoundingCannotRunAway() {
        for lines in 1...40 {
            let height = Double(lines) * line
            let once = StreamingHeightReserve.reserved(measured: height, current: 0, line: line)
            #expect(once == height)
            #expect(StreamingHeightReserve.reserved(measured: once + 0.25, current: once, line: line) == once)
            #expect(StreamingHeightReserve.reserved(measured: once - 0.25, current: once, line: line) == once)
        }
    }

    @Test func theReservationNeverShrinksWhileStreaming() {
        #expect(StreamingHeightReserve.reserved(measured: 20, current: 66, line: line) == 66)
        #expect(StreamingHeightReserve.reserved(measured: 0, current: 66, line: line) == 66)
        #expect(StreamingHeightReserve.reserved(measured: 50, current: 0, line: 0) == 0)
    }
}
