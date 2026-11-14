import SwiftUI

nonisolated struct ChatViewport: Equatable {
    static let prefetchViewports: CGFloat = 2
    static let shortContentViewports: CGFloat = 1.5

    var offset: CGFloat
    var distanceFromNewest: CGFloat
    var distanceFromOldest: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
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
    static let leaveFollowing: CGFloat = 80

    var position = ScrollPosition(idType: String.self, edge: .top)
    private(set) var mode = Mode.following
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    @ObservationIgnored private var phase = ScrollPhase.idle
    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var lastRowID: String?
    @ObservationIgnored private var knownIDs: Set<String> = []
    @ObservationIgnored private var pin: Pin?

    private struct Pin {
        let id: String
        var minY: CGFloat?
        var offset: CGFloat
    }

    var showsJumpButton: Bool { mode == .reading }

    func observe(_ viewport: ChatViewport) {
        offset = viewport.offset
        if wantsOlder != viewport.wantsOlder { wantsOlder = viewport.wantsOlder }
        if viewport.distanceFromNewest <= Self.enterFollowing {
            follow()
        } else if phase.isMoving, viewport.distanceFromNewest > Self.leaveFollowing, mode != .reading {
            mode = .reading
        }
    }

    func observe(_ phase: ScrollPhase) {
        self.phase = phase
    }

    func visibleRowsChanged(_ ids: [String]) {
        guard let first = ids.first else { return }
        if pin?.id != first { pin = Pin(id: first, minY: nil, offset: offset) }
    }

    func rowMoved(_ id: String, minY: CGFloat) {
        guard var current = pin, current.id == id else { return }
        defer {
            current.minY = minY
            current.offset = offset
            pin = current
        }
        guard mode == .reading, phase == .idle, let previous = current.minY,
              abs(offset - current.offset) < 0.5, abs(minY - previous) > 0.5 else { return }
        position.scrollTo(y: offset + (minY - previous))
    }

    func rowsChanged(_ ids: [String]) {
        defer {
            lastRowID = ids.last
            knownIDs = Set(ids)
        }
        guard let last = lastRowID, ids.last != last, let anchor = ids.lastIndex(of: last) else {
            if mode == .following { position.scrollTo(edge: .top) }
            return
        }
        switch mode {
        case .following:
            position.scrollTo(edge: .top)
        case .reading:
            unseen += ids[(anchor + 1)...].count { !knownIDs.contains($0) }
        }
    }

    func contentGrew() {
        if mode == .following { position.scrollTo(edge: .top) }
    }

    func jumpToBottom() {
        follow()
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .top) }
    }

    func reveal(_ id: String) {
        mode = .reading
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(id: id, anchor: .center) }
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
