import Foundation
import PalChat
import Testing

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() % 1_000_000) / 1_000_000 * (range.upperBound - range.lowerBound)
    }

    mutating func chance(_ probability: Double) -> Bool {
        double(0...1) < probability
    }
}

private struct FakeScrollView {
    var ids: [String]
    var heights: [Double]
    var containerHeight = 600.0
    var containerWidth = 400.0
    var insetTop = 0.0
    var insetBottom = 0.0
    var offsetY = 0.0
    var userScrolling = false
    var rng: SplitMix64
    var nextID = 0

    init(rng: SplitMix64) {
        self.rng = rng
        ids = []
        heights = []
        for _ in 0..<12 { appendRow() }
        offsetY = maxOffset
    }

    var content: Double { heights.reduce(0, +) }
    var visibleHeight: Double { containerHeight - insetTop - insetBottom }
    var maxOffset: Double { max(-insetTop, content - visibleHeight - insetTop) }
    var atBottom: Bool { geometry.distanceFromBottom <= ChatScrollMachine.atBottomTolerance }

    var geometry: ChatScrollGeometry {
        ChatScrollGeometry(
            offsetY: offsetY,
            contentHeight: content,
            containerHeight: visibleHeight,
            containerWidth: containerWidth,
            insetTop: insetTop,
            insetBottom: insetBottom,
            topAnchor: topAnchor
        )
    }

    var visibleIDs: [String] {
        let top = max(0, offsetY + insetTop)
        let bottom = top + visibleHeight
        return ids.indices.filter { index in
            let rowTop = self.rowTop(index)
            return rowTop < bottom && rowTop + heights[index] > top
        }.map { ids[$0] }
    }

    private var topAnchor: ChatRowAnchor? {
        guard !ids.isEmpty else { return nil }
        let visibleTop = max(0, offsetY + insetTop)
        let index = ids.indices.last { rowTop($0) <= visibleTop } ?? 0
        return ChatRowAnchor(rowID: ids[index], offsetInRow: visibleTop - rowTop(index))
    }

    func rowTop(_ index: Int) -> Double { heights[..<index].reduce(0, +) }

    mutating func newRow() -> (String, Double) {
        nextID += 1
        return ("r\(nextID)", rng.double(40...220))
    }

    mutating func appendRow() {
        let (id, height) = newRow()
        ids.append(id)
        heights.append(height)
    }

    mutating func prependRow() {
        let (id, height) = newRow()
        ids.insert(id, at: 0)
        heights.insert(height, at: 0)
    }

    mutating func clampOffset() {
        offsetY = min(max(offsetY, -insetTop), maxOffset)
    }

    mutating func sizeChange(_ mutate: (inout FakeScrollView) -> Void) {
        let wasAtBottom = atBottom
        mutate(&self)
        guard wasAtBottom else { return clampOffset() }
        offsetY = maxOffset
    }

    mutating func changeHeight() {
        let index = rng.int(0...(ids.count - 1))
        let delta = rng.double(5...80) * (rng.chance(0.5) ? 1 : -1)
        sizeChange { $0.heights[index] = max(20, $0.heights[index] + delta) }
    }

    mutating func changeInset() {
        let value = rng.double(0...160)
        sizeChange { $0.insetBottom = value + 6 }
    }

    mutating func resize() {
        let height = rng.double(360...800)
        let width = rng.double(300...900)
        sizeChange {
            $0.containerHeight = height
            $0.containerWidth = width
        }
    }

    mutating func userMove() {
        offsetY += rng.double(-400...400)
        clampOffset()
    }

    mutating func wheelMove() {
        offsetY -= rng.double(5...300)
        clampOffset()
    }

    mutating func landOnBottom() { offsetY = maxOffset }

    mutating func land(on anchor: ChatRowAnchor) {
        guard let index = ids.firstIndex(of: anchor.rowID) else { return }
        offsetY = rowTop(index) + anchor.offsetInRow - insetTop
        clampOffset()
    }

    mutating func landNear(rowID: String) {
        guard let index = ids.firstIndex(of: rowID) else { return }
        offsetY = rowTop(index) - containerHeight / 2
        if rng.chance(0.3) { offsetY += rng.double(700...1500) * (rng.chance(0.5) ? 1 : -1) }
        clampOffset()
    }
}

private struct Harness {
    var machine = ChatScrollMachine()
    var fake: FakeScrollView
    let seed: UInt64
    var step = 0
    var fedGeometry: ChatScrollGeometry?
    var fedVisible: [String] = []
    var violations: [String] = []

    init(seed: UInt64) {
        self.seed = seed
        fake = FakeScrollView(rng: SplitMix64(state: seed))
    }

    mutating func start() {
        _ = machine.handle(.rowsChanged(fake.ids))
        syncObservations()
    }

    mutating func syncObservations() {
        if fedGeometry != fake.geometry {
            fedGeometry = fake.geometry
            feed(.geometry(fake.geometry), prepended: false)
        }
        if fedVisible != fake.visibleIDs {
            fedVisible = fake.visibleIDs
            feed(.visibleRowsChanged(fedVisible), prepended: false)
        }
    }

    mutating func feed(_ event: ChatScrollMachine.Event, prepended: Bool) {
        let before = machine.state
        let wasUserScrolling = fake.userScrolling
        let command = machine.handle(event)
        record(event, command: command, before: before, wasUserScrolling: wasUserScrolling, prepended: prepended)
        apply(command)
    }

    mutating func record(
        _ event: ChatScrollMachine.Event,
        command: ChatScrollMachine.Command,
        before: ChatScrollMachine.State,
        wasUserScrolling: Bool,
        prepended: Bool
    ) {
        guard before == .readingHistory, !wasUserScrolling, command != .none else { return }
        switch (event, command) {
        case (.rowsChanged, .restore) where prepended: return
        case (.jumpToNewest, _), (.send, _), (.revealRow, _), (.revealRetry, _): return
        default: violations.append("step \(step): reading emitted \(command.name) for \(event.name)")
        }
    }

    mutating func apply(_ command: ChatScrollMachine.Command) {
        switch command {
        case .none: return
        case .scrollToBottom: fake.landOnBottom()
        case .restore(let anchor): fake.land(on: anchor)
        case .scrollToRow(let id): fake.landNear(rowID: id)
        }
        syncObservations()
    }

    static let actions: [@Sendable (inout Harness) -> Void] = [
        { $0.structural { $0.appendRow() } },
        { $0.structural(prepend: true) { $0.prependRow() } },
        { $0.sizeEvent { $0.changeHeight() } },
        { $0.sizeEvent { $0.changeInset() } },
        { $0.sizeEvent { $0.resize() } },
        { $0.userBegan() },
        { $0.userMoved() },
        { $0.userEnded() },
        { $0.wheelMoved() },
        { $0.feed(.jumpToNewest(animated: $0.fake.rng.chance(0.5)), prepended: false) },
        { $0.feed(.send(animated: $0.fake.rng.chance(0.5)), prepended: false) },
        { $0.reveal() },
        { $0.feed(.revealRetry, prepended: false) },
        { $0.feed(.rowsChanged($0.fake.ids), prepended: false) },
    ]

    mutating func run(_ event: Int) {
        step += 1
        Self.actions[event](&self)
        check()
    }

    mutating func structural(prepend: Bool = false, _ mutate: (inout FakeScrollView) -> Void) {
        fake.sizeChange(mutate)
        feed(.rowsChanged(fake.ids), prepended: prepend)
        syncObservations()
    }

    mutating func sizeEvent(_ mutate: (inout FakeScrollView) -> Void) {
        mutate(&fake)
        syncObservations()
    }

    mutating func userBegan() {
        guard !fake.userScrolling else { return }
        fake.userScrolling = true
        feed(.userScrollBegan, prepended: false)
    }

    mutating func userMoved() {
        guard fake.userScrolling else { return }
        fake.userMove()
        syncObservations()
    }

    mutating func userEnded() {
        guard fake.userScrolling else { return }
        fake.userScrolling = false
        feed(.userScrollEnded, prepended: false)
    }

    mutating func wheelMoved() {
        guard !fake.userScrolling else { return }
        fake.wheelMove()
        syncObservations()
    }

    mutating func reveal() {
        feed(.revealRow(fake.ids[fake.rng.int(0...(fake.ids.count - 1))]), prepended: false)
    }

    mutating func check() {
        guard !fake.userScrolling, machine.state == .pinnedToBottom, fake.geometry.distanceFromBottom > ChatScrollMachine.showDistance else { return }
        var settled = machine
        _ = settled.handle(.geometry(fake.geometry))
        guard settled.state == .pinnedToBottom else { return }
        violations.append("step \(step): pinned but \(fake.geometry.distanceFromBottom) pt from the bottom")
    }
}

@Suite("Chat scroll machine properties")
struct ChatScrollMachinePropertyTests {
    @Test(arguments: Array(1...20))
    func pinnedMeansAtTheBottomAndReadingNeverScrollsByItself(seed: Int) {
        var harness = Harness(seed: UInt64(seed))
        var picker = SplitMix64(state: UInt64(seed) &* 7919)
        harness.start()
        for _ in 0..<400 { harness.run(picker.int(0...(Harness.actions.count - 1))) }
        #expect(harness.violations.isEmpty, "seed \(seed): \(harness.violations.prefix(5))")
    }
}
