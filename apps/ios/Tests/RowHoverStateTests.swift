import Observation
import Synchronization
import Testing

@testable import HermesBots

@MainActor
@Suite("Row hover state")
struct RowHoverStateTests {
    private final class Fired: Sendable {
        private let storage = Mutex(0)
        var count: Int { storage.withLock { $0 } }
        func bump() { storage.withLock { $0 += 1 } }
    }

    private func observe(_ state: RowHoverState, _ fired: Fired) {
        withObservationTracking {
            _ = state.isHovering
        } onChange: {
            fired.bump()
        }
    }

    @Test func hoveringOneRowNotifiesOnlyThatRowsPill() {
        let hovered = RowHoverState()
        let other = RowHoverState()
        let hoveredFired = Fired()
        let otherFired = Fired()
        observe(hovered, hoveredFired)
        observe(other, otherFired)

        hovered.setHovering(true)

        #expect(hoveredFired.count == 1)
        #expect(otherFired.count == 0)
    }

    @Test func repeatingTheSameHoverValueNotifiesNobody() {
        let state = RowHoverState()
        let fired = Fired()
        state.setHovering(true)
        observe(state, fired)
        state.setHovering(true)
        #expect(fired.count == 0)
    }
}
