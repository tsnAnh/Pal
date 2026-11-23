import PalChat
import SwiftUI

@MainActor
@Observable
final class ChatScrollController {
    static let contentSpace = "chatContent"
    static let revealAnchor = UnitPoint(x: 0, y: 0.5)
    static let revealRetryInterval = Duration.milliseconds(250)
    static let glideViewports = 2.0
    static let restoreTolerance = 0.5

    var position = ScrollPosition(idType: String.self, edge: .bottom)
    private(set) var showsJumpButton = false
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    @ObservationIgnored private(set) var machine = ChatScrollMachine()
    @ObservationIgnored private var isMoving = false
    @ObservationIgnored private var lastGeometry: ChatScrollGeometry?
    @ObservationIgnored private var visibleTop = 0.0
    @ObservationIgnored private var visibleIDs: [String] = []
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var pendingRestore: ChatRowAnchor?
    @ObservationIgnored private var heights = ChatRowHeightCache()
    @ObservationIgnored private var recordedIDs: Set<String> = []
    @ObservationIgnored private var lastRows: [String: ChatRow] = [:]
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    func observe(_ geometry: ScrollGeometry) {
        visibleTop = Double(geometry.visibleRect.minY)
        let snapshot = ChatScrollGeometry(
            offsetY: Double(geometry.contentOffset.y),
            contentHeight: Double(geometry.contentSize.height),
            containerHeight: Double(geometry.containerSize.height),
            containerWidth: Double(geometry.containerSize.width),
            insetTop: Double(geometry.contentInsets.top),
            insetBottom: Double(geometry.contentInsets.bottom),
            topAnchor: topAnchor(visibleTop: visibleTop)
        )
        lastGeometry = snapshot
        if wantsOlder != snapshot.wantsOlder { wantsOlder = snapshot.wantsOlder }
        let before = machine.state
        let command = machine.handle(.geometry(snapshot))
        publish()
        if ChatScrollTrace.isOn {
            ChatScrollTrace.geometry(snapshot, state: machine.state.name)
            if command != .none || machine.state != before {
                ChatScrollTrace.machine(event: "geometry", state: machine.state.name, command: command.name)
            }
        }
        perform(command)
    }

    func observe(_ phase: ScrollPhase) {
        if ChatScrollTrace.isOn { ChatScrollTrace.phase(phase, state: machine.state.name) }
        let moving = phase.isMoving
        guard moving != isMoving else { return }
        isMoving = moving
        if moving {
            revealTask?.cancel()
            pendingRestore = nil
            send(.userScrollBegan)
        } else {
            send(.userScrollEnded)
        }
    }

    func rowsChanged(_ ids: [String]) {
        let live = Set(ids)
        frames = frames.filter { live.contains($0.key) }
        lastRows = lastRows.filter { live.contains($0.key) }
        for id in recordedIDs.subtracting(live) { heights.invalidate(id) }
        recordedIDs.formIntersection(live)
        visibleIDs.removeAll { !live.contains($0) }
        if let pending = pendingRestore, !live.contains(pending.rowID) { pendingRestore = nil }
        if ChatScrollTrace.isOn { ChatScrollTrace.rows(ids.count, state: machine.state.name) }
        send(.rowsChanged(ids))
    }

    func visibleRowsChanged(_ ids: [String]) {
        visibleIDs = ids
        send(.visibleRowsChanged(ids))
    }

    func rowLaidOut(_ id: String, frame: CGRect) {
        frames[id] = frame
        if let width = lastGeometry?.containerWidth {
            heights.record(id, height: Double(frame.height), width: width)
            recordedIDs.insert(id)
        }
        guard let pending = pendingRestore, pending.rowID == id else { return }
        perform(.restore(pending), frame: frame)
    }

    func minHeight(for row: ChatRow) -> CGFloat? {
        if lastRows[row.id] != row {
            heights.invalidate(row.id)
            recordedIDs.remove(row.id)
            lastRows[row.id] = row
        }
        guard !row.isStreaming, let width = lastGeometry?.containerWidth,
              let height = heights.height(for: row.id, width: width) else { return nil }
        return CGFloat(height)
    }

    func jumpToBottom(animated: Bool) {
        revealTask?.cancel()
        send(.jumpToNewest(animated: animated))
    }

    func sent(animated: Bool) {
        revealTask?.cancel()
        send(.send(animated: animated))
    }

    func reveal(_ id: String) {
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.send(.revealRow(id))
            for _ in 1..<ChatScrollMachine.revealAttempts {
                try? await Task.sleep(for: Self.revealRetryInterval)
                guard !Task.isCancelled, case .programmatic(.row) = self.machine.state else { return }
                self.send(.revealRetry)
            }
        }
    }

    func perform(_ command: ChatScrollMachine.Command, frame: CGRect? = nil) {
        switch command {
        case .none:
            break
        case .scrollToBottom(let animated):
            let distance = lastGeometry?.distanceFromBottom ?? 0
            let height = lastGeometry?.containerHeight ?? 0
            let glides = animated && distance <= height * Self.glideViewports
            var transaction = Transaction(animation: glides ? .spring(duration: 0.35, bounce: 0) : nil)
            transaction.disablesAnimations = !glides
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        case .scrollToRow(let id):
            withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(id: id, anchor: Self.revealAnchor) }
        case .restore(let anchor):
            guard let frame else {
                pendingRestore = anchor
                return
            }
            pendingRestore = nil
            let target = Double(frame.minY) + anchor.offsetInRow
            guard abs(visibleTop - target) > Self.restoreTolerance else { return }
            position.scrollTo(y: CGFloat(target)) // perf-lint: ok
        }
    }

    private func send(_ event: ChatScrollMachine.Event) {
        let command = machine.handle(event)
        publish()
        if ChatScrollTrace.isOn {
            ChatScrollTrace.machine(event: event.name, state: machine.state.name, command: command.name)
        }
        perform(command)
    }

    private func publish() {
        if showsJumpButton != machine.showsJumpButton { showsJumpButton = machine.showsJumpButton }
        if unseen != machine.unseen { unseen = machine.unseen }
    }

    private func topAnchor(visibleTop: Double) -> ChatRowAnchor? {
        var below: (id: String, minY: Double)?
        for id in visibleIDs {
            guard let frame = frames[id] else { continue }
            let minY = Double(frame.minY)
            if minY <= visibleTop, visibleTop < Double(frame.maxY) {
                return ChatRowAnchor(rowID: id, offsetInRow: visibleTop - minY)
            }
            if minY > visibleTop, minY < (below?.minY ?? .infinity) { below = (id, minY) }
        }
        return below.map { ChatRowAnchor(rowID: $0.id, offsetInRow: visibleTop - $0.minY) }
    }
}

private extension ScrollPhase {
    var isMoving: Bool { self == .interacting || self == .decelerating || self == .tracking }
}
