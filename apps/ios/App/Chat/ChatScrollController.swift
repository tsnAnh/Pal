import PalChat
import PalDiagnostics
import SwiftUI

@MainActor
@Observable
final class ChatScrollController {
    static let contentSpace = "chatContent"
    static let revealAnchor = UnitPoint(x: 0, y: 0.5)
    static let revealRetryInterval = Duration.milliseconds(250)
    static let glideViewports = 2.0
    static let restoreTolerance = 0.5
    static let measureBatchSize = 4
    static let measureTimeout = Duration.milliseconds(400)
    static let resizeSettle = Duration.milliseconds(150)
    static let tailLeadViewports = 2.0
    static let holdWindow = Duration.milliseconds(400)

    var position = ScrollPosition(idType: String.self, edge: .bottom)
    private(set) var showsJumpButton = false
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    var measureTick = 0
    var planTick = 0
    @ObservationIgnored private(set) var machine = ChatScrollMachine()
    @ObservationIgnored private var isMoving = false
    @ObservationIgnored private(set) var lastGeometry: ChatScrollGeometry?
    @ObservationIgnored private var visibleTop = 0.0
    @ObservationIgnored private var visibleIDs: [String] = []
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var pendingRestore: ChatRowAnchor?
    @ObservationIgnored let rowHeights: ChatRowHeights
    @ObservationIgnored var resizeSettleTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var deferred: (command: ChatScrollMachine.Command, frame: CGRect?) = (.none, nil)
    @ObservationIgnored private var deferredWrite: Task<Void, Never>?
    @ObservationIgnored let planner: ChatTailPlanner
    @ObservationIgnored let tracker = ChatOpenTracker()
    @ObservationIgnored var heights: (store: ChatRowHeightStore, bot: String)?
    @ObservationIgnored private var writers = ChatScrollWriterLedger()
    @ObservationIgnored var newestAnchor: ChatNewestAnchor?
    @ObservationIgnored var holdsUntil = ContinuousClock.now
    @ObservationIgnored private var wasRunning: Bool?
    @ObservationIgnored private var contentLedger = ChatContentLedger()
    @ObservationIgnored private var phaseName = "idle"
    @ObservationIgnored var sampleSink: ((ChatScrollSample) -> Void)?
    @ObservationIgnored var rowSink: ((String, CGRect) -> Void)?

    init(layout: ChatLayoutMemory = ChatLayoutMemory()) {
        rowHeights = layout.rowHeights
        planner = layout.planner
    }

    var isPinnedToBottom: Bool { machine.state == .pinnedToBottom }

    private var isRecording: Bool { ChatScrollTrace.isOn || sampleSink != nil }

    func observe(_ geometry: ScrollGeometry) {
        ChatOpenMetrics.geometry()
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
        let previousGeometry = lastGeometry
        lastGeometry = snapshot
        let wantsOlderNow = observeTail(snapshot)
        if wantsOlder != wantsOlderNow { wantsOlder = wantsOlderNow }
        if abs((previousGeometry?.containerWidth ?? 0) - snapshot.containerWidth) > Self.restoreTolerance {
            widthMoved()
        }
        let before = machine.state
        let command = machine.handle(.geometry(snapshot))
        publish()
        if isRecording {
            let sample = ChatScrollSample(
                geometry: snapshot, state: machine.state.name, showsButton: showsJumpButton,
                userScrolling: machine.isUserScrolling, phase: phaseName,
                writer: writers.attribute(from: previousGeometry, to: snapshot, userMoving: isMoving),
                offsetDelta: previousGeometry.map { snapshot.offsetY - $0.offsetY } ?? 0,
                contentDelta: previousGeometry.map { snapshot.contentHeight - $0.contentHeight } ?? 0,
                contentSource: contentLedger.attribute(from: previousGeometry, to: snapshot)
            )
            sampleSink?(sample)
            ChatScrollTrace.geometry(sample)
            if command != .none || machine.state != before {
                ChatScrollTrace.machine(event: "geometry", state: machine.state.name, command: command.name)
            }
        }
        performNextTurn(command)
    }

    func observe(_ phase: ScrollPhase) {
        if isRecording { phaseName = "\(phase)" }
        if ChatScrollTrace.isOn { ChatScrollTrace.phase(phase, state: machine.state.name) }
        let moving = phase.isMoving
        guard moving != isMoving else { return }
        isMoving = moving
        if moving {
            revealTask?.cancel()
            deferredWrite?.cancel()
            deferredWrite = nil
            deferred = (.none, nil)
            pendingRestore = nil
            send(.userScrollBegan)
        } else {
            send(.userScrollEnded)
        }
    }

    func rowsChanged(_ ids: [String]) {
        let live = Set(ids)
        frames = frames.filter { live.contains($0.key) }
        rowHeights.rowsChanged(live)
        visibleIDs.removeAll { !live.contains($0) }
        if let pending = pendingRestore, !live.contains(pending.rowID) { pendingRestore = nil }
        if isRecording { contentLedger.noteRows() }
        let rendered = noteRendered(planner.rendered(from: ids))
        if ChatScrollTrace.isOn { ChatScrollTrace.rows(rendered.count, state: machine.state.name) }
        send(.rowsChanged(rendered))
    }

    func streamingChanged(_ running: Bool) {
        if wasRunning == true, !running { armDocumentHold() }
        wasRunning = running
        contentLedger.noteStreaming(running)
    }

    func visibleRowsChanged(_ ids: [String]) {
        visibleIDs = ids
        send(.visibleRowsChanged(ids))
    }

    func rowLaidOut(_ id: String, frame: CGRect) {
        ChatOpenMetrics.rowLaidOut(id)
        frames[id] = frame
        rowSink?(id, frame)
        holdNewestRow(id, frame: frame)
        if let width = lastGeometry?.containerWidth { noteLaidOut(id, height: Double(frame.height), width: width) }
        guard let pending = pendingRestore, pending.rowID == id else { return }
        performNextTurn(.restore(pending), frame: frame)
    }

    var measureWidth: CGFloat? {
        guard let width = lastGeometry?.containerWidth, width > 0 else { return nil }
        return CGFloat(width)
    }

    func measureBatch(of rows: [ChatRow]) -> [ChatRow] {
        _ = measureTick
        guard resizeSettleTask == nil, let width = lastGeometry?.containerWidth, width > 0 else { return [] }
        return rowHeights.batch(of: rows, width: width)
    }

    func measured(_ row: ChatRow, height: CGFloat) {
        guard let width = lastGeometry?.containerWidth, width > 0 else { return }
        rowHeights.measured(row, height: Double(height), width: width)
        measureTick &+= 1
    }

    func measureGaveUp(on ids: [String]) {
        guard let width = lastGeometry?.containerWidth, rowHeights.giveUp(on: ids, width: width) else { return }
        measureTick &+= 1
    }

    func minHeight(for row: ChatRow) -> CGFloat? {
        rowHeights.minHeight(for: row, width: lastGeometry?.containerWidth)
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
        if planner.reveal(id) { tailMoved() }
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

    private func performNextTurn(_ command: ChatScrollMachine.Command, frame: CGRect? = nil) {
        guard command != .none else { return }
        deferred = (command, frame)
        guard deferredWrite == nil else { return }
        deferredWrite = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            deferredWrite = nil
            let (command, frame) = deferred
            deferred = (.none, nil)
            perform(command, frame: frame)
        }
    }

    func perform(_ command: ChatScrollMachine.Command, frame: CGRect? = nil) {
        switch command {
        case .none:
            break
        case .scrollToBottom(let animated):
            let distanceFromBottom = machine.distanceFromBottom ?? 0
            switch machine.state {
            case .programmatic(.bottom): break
            case .pinnedToBottom where distanceFromBottom > ChatScrollMachine.atBottomTolerance: break
            default: return
            }
            let height = lastGeometry?.containerHeight ?? 0
            let glides = animated && distanceFromBottom <= height * Self.glideViewports
            var transaction = Transaction(animation: glides ? .spring(duration: 0.35, bounce: 0) : nil)
            transaction.disablesAnimations = !glides
            notePositionWrite(command)
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        case .clampToContent:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            notePositionWrite(command)
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        case .scrollToRow(let id):
            notePositionWrite(command)
            withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(id: id, anchor: Self.revealAnchor) }
        case .restore(let anchor):
            guard let frame else {
                pendingRestore = anchor
                return
            }
            pendingRestore = nil
            let target = Double(frame.minY) + anchor.offsetInRow
            guard abs(visibleTop - target) > Self.restoreTolerance else { return }
            notePositionWrite(command)
            position.scrollTo(y: CGFloat(target)) // perf-lint: ok
        }
    }

    private func notePositionWrite(_ command: ChatScrollMachine.Command) {
        if isRecording { writers.noteWrite(command) }
        ChatOpenMetrics.positionWrite()
        PalPerf.event("chat.scroll.write")
    }

    func send(_ event: ChatScrollMachine.Event) {
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
