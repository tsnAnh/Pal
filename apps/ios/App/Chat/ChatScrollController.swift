import SwiftUI

nonisolated struct ChatViewport: Equatable {
    static let prefetchViewports: CGFloat = 2
    static let shortContentViewports: CGFloat = 1.5

    var distanceFromTop: CGFloat
    var distanceFromBottom: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        distanceFromTop = geometry.contentOffset.y + geometry.contentInsets.top
        distanceFromBottom = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        viewportHeight = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
    }

    var wantsOlder: Bool {
        distanceFromTop < viewportHeight * Self.prefetchViewports
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

    var position = ScrollPosition(idType: String.self)
    private(set) var mode = Mode.following
    private(set) var unseen = 0
    private(set) var wantsOlder = false
    private var userScrolling = false
    private var lastRowID: String?
    private var knownIDs: Set<String> = []

    var showsJumpButton: Bool { mode == .reading }

    func observe(_ viewport: ChatViewport) {
        wantsOlder = viewport.wantsOlder
        if viewport.distanceFromBottom <= Self.enterFollowing {
            follow()
        } else if userScrolling, viewport.distanceFromBottom > Self.leaveFollowing {
            mode = .reading
        }
    }

    func observe(_ phase: ScrollPhase) {
        userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
    }

    func rowsChanged(_ ids: [String]) {
        defer {
            lastRowID = ids.last
            knownIDs = Set(ids)
        }
        guard let last = lastRowID else {
            if !ids.isEmpty { position.scrollTo(edge: .bottom) }
            return
        }
        guard ids.last != last, let anchor = ids.lastIndex(of: last) else {
            if mode == .following { position.scrollTo(edge: .bottom) }
            return
        }
        switch mode {
        case .following:
            position.scrollTo(edge: .bottom)
        case .reading:
            unseen += ids[(anchor + 1)...].count { !knownIDs.contains($0) }
        }
    }

    func contentGrew() {
        if mode == .following { position.scrollTo(edge: .bottom) }
    }

    func jumpToBottom() {
        follow()
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
    }

    func reveal(_ id: String) {
        mode = .reading
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(id: id, anchor: .center) }
        }
    }

    private func follow() {
        mode = .following
        unseen = 0
    }
}
