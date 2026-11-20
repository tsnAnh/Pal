import Observation
import Synchronization
import Testing

@testable import HermesBots

private struct GateState {
    var waiting: [CheckedContinuation<Void, Never>] = []
    var requested: [Duration] = []
}

@MainActor
@Suite("Row hover state")
struct RowHoverStateTests {
    private final class Fired: Sendable {
        private let storage = Mutex(0)
        var count: Int { storage.withLock { $0 } }
        func bump() { storage.withLock { $0 += 1 } }
    }

    private final class SleepGate: Sendable {
        private let storage = Mutex(GateState())
        var waiters: Int { storage.withLock { $0.waiting.count } }
        var requested: [Duration] { storage.withLock { $0.requested } }

        func sleep(_ duration: Duration) async throws {
            await withCheckedContinuation { continuation in
                storage.withLock {
                    $0.requested.append(duration)
                    $0.waiting.append(continuation)
                }
            }
        }

        func open() {
            let released = storage.withLock { gate in
                let taken = gate.waiting
                gate.waiting = []
                return taken
            }
            released.forEach { $0.resume() }
        }
    }

    private func observe(_ state: RowHoverState, _ fired: Fired) {
        withObservationTracking {
            _ = state.isHovering
        } onChange: {
            fired.bump()
        }
    }

    private func gatedState() -> (RowHoverState, SleepGate) {
        let gate = SleepGate()
        return (RowHoverState(sleep: { try await gate.sleep($0) }), gate)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func hoveringOneRowNotifiesOnlyThatRowsPill() {
        let hovered = RowHoverState()
        let other = RowHoverState()
        let hoveredFired = Fired()
        let otherFired = Fired()
        observe(hovered, hoveredFired)
        observe(other, otherFired)

        hovered.enter(.message)

        #expect(hoveredFired.count == 1)
        #expect(otherFired.count == 0)
    }

    @Test func enteringTheBarWhileAlreadyHoveringNotifiesNobody() {
        let state = RowHoverState()
        let fired = Fired()
        state.enter(.message)
        observe(state, fired)
        state.enter(.bar)
        #expect(fired.count == 0)
    }

    @Test func leavingTheBubbleForTheBarKeepsHoverWithoutStartingTheDelay() async {
        let (state, gate) = gatedState()
        state.enter(.message)
        state.enter(.bar)
        state.exit(.message)
        await settle()

        #expect(state.isHovering)
        #expect(gate.waiters == 0)
    }

    @Test func leavingBothRegionsWaitsTheHideDelayThenHides() async {
        let (state, gate) = gatedState()
        state.enter(.message)
        state.enter(.bar)
        state.exit(.message)
        state.exit(.bar)
        await until { gate.waiters == 1 }

        #expect(state.isHovering)
        #expect(gate.requested == [.milliseconds(120)])

        gate.open()
        await until { !state.isHovering }

        #expect(!state.isHovering)
    }

    @Test func reenteringWithinTheDelayCancelsTheHide() async {
        let (state, gate) = gatedState()
        state.enter(.message)
        state.exit(.message)
        await until { gate.waiters == 1 }
        #expect(gate.waiters == 1)

        state.enter(.message)
        gate.open()
        await settle()

        #expect(state.isHovering)
    }

    @Test func aSecondExitWhileWaitingStartsNoSecondDelay() async {
        let (state, gate) = gatedState()
        state.enter(.message)
        state.enter(.bar)
        state.exit(.message)
        state.exit(.bar)
        await until { gate.waiters == 1 }
        state.exit(.bar)
        await settle()

        #expect(gate.waiters == 1)
    }

    @Test func exitingARegionNeverEnteredStaysHidden() async {
        let (state, gate) = gatedState()
        state.exit(.message)
        await settle()

        #expect(!state.isHovering)
        #expect(gate.waiters == 0)
    }
}
