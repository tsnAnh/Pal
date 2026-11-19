import PalDiagnostics
import SwiftUI

nonisolated struct ChatViewport: Equatable {
    static let prefetchViewports: CGFloat = 2
    static let shortContentViewports: CGFloat = 1.5

    var distanceFromNewest: CGFloat
    var distanceFromOldest: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        distanceFromNewest = geometry.contentOffset.y + geometry.contentInsets.top
        distanceFromOldest = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        viewportHeight = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
    }

    var wantsOlder: Bool {
        distanceFromOldest < viewportHeight * Self.prefetchViewports
            || contentHeight < viewportHeight * Self.shortContentViewports
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

    var position = ScrollPosition(idType: String.self, edge: .top)
    private(set) var mode = Mode.following
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    private(set) var pinnedID: String?
    @ObservationIgnored private var phase = ScrollPhase.idle
    @ObservationIgnored private var distanceFromNewest: CGFloat = 0
    @ObservationIgnored private var viewportHeight: CGFloat = 0
    @ObservationIgnored private var lastRowID: String?
    @ObservationIgnored private var knownIDs: Set<String> = []
    @ObservationIgnored private var pin: Pin?
    @ObservationIgnored private var revealing = false
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    static let revealSettle = Duration.milliseconds(250)
    static let revealAttempts = 12

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
        viewportHeight = viewport.viewportHeight
        if wantsOlder != viewport.wantsOlder { wantsOlder = viewport.wantsOlder }
        if viewport.distanceFromNewest <= Self.enterFollowing, !revealing {
            follow()
        } else if phase.isMoving, viewport.distanceFromNewest > Self.leaveFollowing, mode != .reading {
            mode = .reading
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
            pinnedID = first
        }
    }

    func rowMoved(_ id: String, contentMinY: CGFloat) {
        PalPerf.event("chat.scroll.rowMoved")
        guard var current = pin, current.id == id else { return }
        let previous = current.contentMinY
        current.contentMinY = contentMinY
        pin = current
        guard mode == .reading, phase == .idle, let previous, abs(contentMinY - previous) > 0.5 else { return }
        distanceFromNewest += contentMinY - previous
        position.scrollTo(y: distanceFromNewest)
    }

    func rowsChanged(_ ids: [String]) {
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
        keepNewestInView()
    }

    private func keepNewestInView() {
        guard mode == .following, !phase.isMoving else { return }
        position.scrollTo(edge: .top)
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
            withAnimation(.easeInOut(duration: 0.25)) { self?.position.scrollTo(id: id, anchor: .center) }
            for _ in 1..<Self.revealAttempts {
                try? await Task.sleep(for: Self.revealSettle)
                guard let self, !Task.isCancelled, self.revealing, !self.visibleIDs.contains(id) else { return }
                self.position.scrollTo(id: id, anchor: .center)
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

    var body: some View {
        if scroll.pinnedID == id {
            Color.clear.onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(ChatScrollController.contentSpace)).minY
            } action: { scroll.rowMoved(id, contentMinY: $0) }
        }
    }
}
