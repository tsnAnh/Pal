import PalDiagnostics
import SwiftUI

nonisolated struct ChatViewport: Equatable {
    static let prefetchViewports: CGFloat = 2
    static let shortContentViewports: CGFloat = 1.5

    var distanceFromNewest: CGFloat
    var distanceFromOldest: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat

    var wantsOlder: Bool {
        distanceFromOldest < viewportHeight * Self.prefetchViewports
            || contentHeight < viewportHeight * Self.shortContentViewports
    }
}

extension ChatViewport {
    nonisolated init(_ geometry: ScrollGeometry) {
        self.init(
            distanceFromNewest: geometry.contentOffset.y + geometry.contentInsets.top,
            distanceFromOldest: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
            viewportHeight: geometry.containerSize.height,
            contentHeight: geometry.contentSize.height
        )
    }
}

@MainActor
@Observable
final class ChatScrollController {
    enum Mode: Equatable {
        case following
        case reading
    }

    static let enterFollowing: CGFloat = 24
    static let contentSpace = "chatContent"
    static let leaveFollowing: CGFloat = 80
    static let atNewestTolerance: CGFloat = 0.5
    static let revealAnchor = UnitPoint(x: 0, y: 0.5)

    var position = ScrollPosition(idType: String.self, edge: .top)
    private(set) var mode = Mode.following
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    @ObservationIgnored let pinSlots = ChatPinSlots()
    @ObservationIgnored private var phase = ScrollPhase.idle
    @ObservationIgnored private var distanceFromNewest: CGFloat = 0
    @ObservationIgnored private var viewportHeight: CGFloat = 0
    @ObservationIgnored private var lastRowID: String?
    @ObservationIgnored private var knownIDs: Set<String> = []
    @ObservationIgnored private var pin: Pin?
    @ObservationIgnored private var revealing = false
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var repin = Repin.idle
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private var hasMeasured = false
    @ObservationIgnored private var syncPending = false
    @ObservationIgnored private var anchorDrift: CGFloat = 0
    static let revealSettle = Duration.milliseconds(250)
    static let revealAttempts = 12

    private enum Repin {
        case idle
        case pinning
        case done
    }

    private struct Pin {
        let id: String
        var contentMinY: CGFloat?
    }

    var showsJumpButton: Bool { mode == .reading }

    func observe(_ viewport: ChatViewport, tracksOpen: Bool = false) {
        if tracksOpen, !phase.isMoving, abs(viewport.distanceFromNewest - distanceFromNewest) > 0.5 {
            PalPerf.event("chat.open.jump")
        }
        distanceFromNewest = viewport.distanceFromNewest
        hasMeasured = true
        viewportHeight = viewport.viewportHeight
        if wantsOlder != viewport.wantsOlder { wantsOlder = viewport.wantsOlder }
        if viewport.distanceFromNewest <= Self.enterFollowing, !revealing {
            follow()
        } else if phase.isMoving, viewport.distanceFromNewest > Self.leaveFollowing, mode != .reading {
            mode = .reading
        }
        repinWhileOpening(viewport, tracksOpen: tracksOpen)
    }

    private func repinWhileOpening(_ viewport: ChatViewport, tracksOpen: Bool) {
        guard tracksOpen else {
            repin = .idle
            return
        }
        switch repin {
        case .idle:
            guard mode == .following, !revealing, !phase.isMoving,
                  viewport.distanceFromNewest > Self.atNewestTolerance else { return }
            repin = .pinning
            write { $0.scrollTo(y: 0) }
        case .pinning:
            guard viewport.distanceFromNewest <= Self.atNewestTolerance else { return }
            repin = .done
            write { $0.scrollTo(edge: .top) }
        case .done:
            break
        }
    }

    func observe(_ phase: ScrollPhase) {
        self.phase = phase
        if phase.isMoving {
            revealing = false
            revealTask?.cancel()
        }
    }

    func visibleRowsChanged(_ ids: [String]) {
        visibleIDs = Set(ids)
        guard let first = ids.first else { return }
        if pin?.id != first {
            pin = Pin(id: first, contentMinY: nil)
            pinSlots.pin(first)
        }
    }

    func rowMoved(_ id: String, contentMinY: CGFloat) {
        PalPerf.event("chat.scroll.rowMoved")
        guard var current = pin, current.id == id else { return }
        let previous = current.contentMinY
        current.contentMinY = contentMinY
        pin = current
        guard mode == .reading, phase == .idle, let previous, abs(contentMinY - previous) > 0.5 else { return }
        let delta = contentMinY - previous
        guard isVisible else {
            anchorDrift += delta
            PalPerf.event("chat.scroll.bookkeeping.skipped")
            return
        }
        distanceFromNewest += delta
        write { $0.scrollTo(y: distanceFromNewest) }
    }

    func setVisible(_ visible: Bool, rowIDs: [String]) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard visible else { return }
        if anchorDrift != 0, mode == .reading, phase == .idle {
            distanceFromNewest += anchorDrift
            write { $0.scrollTo(y: distanceFromNewest) }
        }
        anchorDrift = 0
        guard syncPending else { return }
        syncPending = false
        rowsChanged(rowIDs)
    }

    func rowsChanged(_ ids: [String]) {
        guard isVisible else {
            deferSync()
            return
        }
        defer {
            lastRowID = ids.last
            knownIDs = Set(ids)
        }
        guard let last = lastRowID, ids.last != last, let anchor = ids.lastIndex(of: last) else {
            keepNewestInView()
            return
        }
        switch mode {
        case .following:
            keepNewestInView()
        case .reading:
            unseen += ids[(anchor + 1)...].count { !knownIDs.contains($0) }
        }
    }

    func contentGrew() {
        guard isVisible else {
            deferSync()
            return
        }
        keepNewestInView()
    }

    private func deferSync() {
        syncPending = true
        PalPerf.event("chat.scroll.bookkeeping.skipped")
    }

    private func keepNewestInView() {
        guard mode == .following, !phase.isMoving else { return }
        guard !hasMeasured || distanceFromNewest > Self.atNewestTolerance else {
            PalPerf.event("chat.scroll.position.skipped")
            return
        }
        write { $0.scrollTo(edge: .top) }
    }

    private func write(_ change: (inout ScrollPosition) -> Void) {
        var next = position
        change(&next)
        guard next != position else {
            PalPerf.event("chat.scroll.position.skipped")
            return
        }
        position = next
        PalPerf.event("chat.scroll.position.write")
    }

    static let jumpGlideViewports: CGFloat = 2

    func jumpToBottom(animated: Bool) {
        revealing = false
        revealTask?.cancel()
        follow()
        let glides = animated && distanceFromNewest <= viewportHeight * Self.jumpGlideViewports
        var transaction = Transaction(animation: glides ? .spring(duration: 0.35, bounce: 0) : nil)
        transaction.disablesAnimations = !glides
        withTransaction(transaction) { position.scrollTo(edge: .top) }
    }

    func reveal(_ id: String) {
        revealing = true
        mode = .reading
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) { self?.position.scrollTo(id: id, anchor: Self.revealAnchor) }
            for _ in 1..<Self.revealAttempts {
                try? await Task.sleep(for: Self.revealSettle)
                guard let self, !Task.isCancelled, self.revealing, !self.visibleIDs.contains(id) else { return }
                self.position.scrollTo(id: id, anchor: Self.revealAnchor)
            }
        }
    }

    private func follow() {
        if mode != .following { mode = .following }
        if unseen != 0 { unseen = 0 }
    }
}

private extension ScrollPhase {
    var isMoving: Bool { self == .interacting || self == .decelerating || self == .tracking }
}

struct ChatPinProbe: View {
    let id: String
    let scroll: ChatScrollController
    let slot: ChatPinSlot

    var body: some View {
        if slot.isPinned {
            Color.clear.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(ChatScrollController.contentSpace)).minY
            } action: { scroll.rowMoved(id, contentMinY: $0) }
        }
    }
}
