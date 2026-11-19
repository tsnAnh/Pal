import Foundation
import Observation
import Synchronization
import Testing
@testable import PalDesign

private final class Counter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@MainActor
private func notifications(of width: DragWidth, during body: () -> Void) -> Int {
    let counter = Counter()
    withObservationTracking { _ = width.live } onChange: { counter.bump() }
    body()
    return counter.value
}

@MainActor
private struct Fixture {
    let writes = WriteLog()
    let width: DragWidth

    init(stored: Double = 280, range: ClosedRange<Double> = 240...400) {
        let log = writes
        width = DragWidth(stored: stored, range: range) { log.record($0) }
    }
}

@MainActor
private final class WriteLog {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}

@MainActor
struct DragWidthTests {
    @Test func manyTicksWriteStorageOnceWhenTheDragEnds() {
        let fixture = Fixture()
        for tick in 1...200 { fixture.width.drag(by: Double(tick)) }
        #expect(fixture.writes.values.isEmpty)
        fixture.width.endDrag()
        #expect(fixture.writes.values == [400])
        #expect(fixture.width.live == 400)
    }

    @Test func eachTickFollowsTheCursorFromTheDragOrigin() {
        let fixture = Fixture()
        fixture.width.drag(by: 10)
        fixture.width.drag(by: 30)
        #expect(fixture.width.live == 310)
        fixture.width.drag(by: -20)
        #expect(fixture.width.live == 260)
    }

    @Test func widthClampsToTheRangeAtBothEnds() {
        let fixture = Fixture()
        fixture.width.drag(by: 5_000)
        #expect(fixture.width.live == 400)
        fixture.width.drag(by: -5_000)
        #expect(fixture.width.live == 240)
    }

    @Test func aStoredWidthOutsideTheRangeIsClamped() {
        #expect(Fixture(stored: 10).width.live == 240)
        #expect(Fixture(stored: 900).width.live == 400)
    }

    @Test func nextDragStartsFromTheCommittedWidth() {
        let fixture = Fixture()
        fixture.width.drag(by: 40)
        fixture.width.endDrag()
        fixture.width.drag(by: 10)
        #expect(fixture.width.live == 330)
        fixture.width.endDrag()
        #expect(fixture.writes.values == [320, 330])
    }

    @Test func endingWithoutAMoveOrBackAtTheStartWritesNothing() {
        let fixture = Fixture()
        fixture.width.endDrag()
        fixture.width.drag(by: 25)
        fixture.width.drag(by: 0)
        fixture.width.endDrag()
        fixture.width.endDrag()
        #expect(fixture.writes.values.isEmpty)
        #expect(fixture.width.live == 280)
    }

    @Test func endingTwiceWritesOnce() {
        let fixture = Fixture()
        fixture.width.drag(by: 50)
        fixture.width.endDrag()
        fixture.width.endDrag()
        #expect(fixture.writes.values == [330])
    }

    @Test func aTickThatChangesTheWidthNotifiesItsReaderAndStorageNeverDoes() {
        let fixture = Fixture()
        let duringTick = notifications(of: fixture.width) { fixture.width.drag(by: 12) }
        #expect(duringTick == 1)
        #expect(fixture.writes.values.isEmpty)
        let duringEnd = notifications(of: fixture.width) { fixture.width.endDrag() }
        #expect(duringEnd == 0)
        #expect(fixture.writes.values == [292])
    }

    @Test func aTickPinnedAtTheLimitNotifiesNobody() {
        let fixture = Fixture()
        fixture.width.drag(by: 5_000)
        let pinned = notifications(of: fixture.width) {
            fixture.width.drag(by: 6_000)
            fixture.width.drag(by: 9_000)
        }
        #expect(pinned == 0)
    }
}
