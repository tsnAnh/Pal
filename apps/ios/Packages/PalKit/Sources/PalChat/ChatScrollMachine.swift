import Foundation

public struct ChatRowAnchor: Sendable, Equatable {
    public var rowID: String
    public var offsetInRow: Double

    public init(rowID: String, offsetInRow: Double) {
        self.rowID = rowID
        self.offsetInRow = offsetInRow
    }
}

public struct ChatScrollGeometry: Sendable, Equatable {
    public var offsetY: Double
    public var contentHeight: Double
    public var containerHeight: Double
    public var containerWidth: Double
    public var insetTop: Double
    public var insetBottom: Double
    public var topAnchor: ChatRowAnchor?

    public init(
        offsetY: Double,
        contentHeight: Double,
        containerHeight: Double,
        containerWidth: Double,
        insetTop: Double,
        insetBottom: Double,
        topAnchor: ChatRowAnchor? = nil
    ) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.containerWidth = containerWidth
        self.insetTop = insetTop
        self.insetBottom = insetBottom
        self.topAnchor = topAnchor
    }

    public var distanceFromBottom: Double { max(0, contentHeight + insetBottom - containerHeight - offsetY) }
    public var distanceFromTop: Double { max(0, offsetY + insetTop) }
    public var wantsOlder: Bool { distanceFromTop < containerHeight * 2 || contentHeight < containerHeight * 1.5 }

    public func sameSize(as other: ChatScrollGeometry) -> Bool {
        abs(contentHeight - other.contentHeight) <= 0.5
            && abs(containerHeight - other.containerHeight) <= 0.5
            && abs(containerWidth - other.containerWidth) <= 0.5
            && abs(insetTop - other.insetTop) <= 0.5
            && abs(insetBottom - other.insetBottom) <= 0.5
    }
}

public struct ChatScrollMachine: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case bottom
        case row(String)
    }

    public enum State: Sendable, Equatable {
        case pinnedToBottom
        case readingHistory
        case programmatic(Target)

        public var name: String {
            switch self {
            case .pinnedToBottom: "pinnedToBottom"
            case .readingHistory: "readingHistory"
            case .programmatic: "programmatic"
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case geometry(ChatScrollGeometry)
        case userScrollBegan
        case userScrollEnded
        case rowsChanged([String])
        case visibleRowsChanged([String])
        case jumpToNewest(animated: Bool)
        case send(animated: Bool)
        case revealRow(String)
        case revealRetry

        public var name: String {
            switch self {
            case .geometry: "geometry"
            case .userScrollBegan: "userScrollBegan"
            case .userScrollEnded: "userScrollEnded"
            case .rowsChanged: "rowsChanged"
            case .visibleRowsChanged: "visibleRowsChanged"
            case .jumpToNewest: "jumpToNewest"
            case .send: "send"
            case .revealRow: "revealRow"
            case .revealRetry: "revealRetry"
            }
        }
    }

    public enum Command: Sendable, Equatable {
        case none
        case scrollToBottom(animated: Bool)
        case restore(ChatRowAnchor)
        case scrollToRow(String)

        public var name: String {
            switch self {
            case .none: "none"
            case .scrollToBottom: "scrollToBottom"
            case .restore: "restore"
            case .scrollToRow: "scrollToRow"
            }
        }
    }

    public static let atBottomTolerance = 1.0
    public static let showDistance = 80.0
    public static let hideDistance = 24.0
    public static let maxRepairs = 3
    public static let revealAttempts = 12

    public private(set) var state: State = .pinnedToBottom
    public private(set) var unseen = 0

    private var userScrolling = false
    private var repairs = 0
    private var attempts = 0
    private var pendingRestore: ChatRowAnchor?
    private var readingAnchor: ChatRowAnchor?
    private var last: ChatScrollGeometry?
    private var previous: ChatScrollGeometry?
    private var knownIDs: [String]?
    private var visibleIDs: Set<String> = []

    public init() {}

    public var isUserScrolling: Bool { userScrolling }

    public var showsJumpButton: Bool {
        switch state {
        case .readingHistory: true
        case .programmatic(.row): true
        case .pinnedToBottom, .programmatic(.bottom): false
        }
    }

    public mutating func handle(_ event: Event) -> Command {
        switch event {
        case .geometry(let geometry): return handleGeometry(geometry)
        case .userScrollBegan: userScrollBegan(); return .none
        case .userScrollEnded: userScrollEnded(); return .none
        case .rowsChanged(let ids): return rowsChanged(ids)
        case .visibleRowsChanged(let ids): visibleRowsChanged(ids); return .none
        case .jumpToNewest(let animated), .send(let animated): return jump(animated: animated)
        case .revealRow(let id): return revealRow(id)
        case .revealRetry: return revealRetry()
        }
    }

    private func isAtBottom(_ geometry: ChatScrollGeometry) -> Bool {
        geometry.distanceFromBottom <= Self.atBottomTolerance
    }

    private var lastIsAtBottom: Bool { last.map(isAtBottom) ?? false }

    private mutating func handleGeometry(_ geometry: ChatScrollGeometry) -> Command {
        let sizeChanged = last.map { !geometry.sameSize(as: $0) } ?? true
        previous = last
        last = geometry
        if userScrolling { return userScrollingGeometry(geometry) }
        switch state {
        case .pinnedToBottom: return pinnedGeometry(geometry, sizeChanged: sizeChanged)
        case .readingHistory: readingGeometry(geometry)
        case .programmatic(.bottom): return programmaticBottomGeometry(geometry, sizeChanged: sizeChanged)
        case .programmatic(.row): break
        }
        return .none
    }

    private mutating func userScrollingGeometry(_ geometry: ChatScrollGeometry) -> Command {
        if state == .pinnedToBottom, !isAtBottom(geometry) { state = .readingHistory }
        readingAnchor = geometry.topAnchor ?? readingAnchor
        return .none
    }

    private mutating func pinnedGeometry(_ geometry: ChatScrollGeometry, sizeChanged: Bool) -> Command {
        if isAtBottom(geometry) {
            repairs = 0
            return .none
        }
        if !sizeChanged, repairs == 0 {
            state = .readingHistory
            readingAnchor = geometry.topAnchor ?? readingAnchor
            return .none
        }
        return repair()
    }

    private mutating func repair() -> Command {
        guard repairs < Self.maxRepairs else { return .none }
        repairs += 1
        return .scrollToBottom(animated: false)
    }

    private mutating func readingGeometry(_ geometry: ChatScrollGeometry) {
        if isAtBottom(geometry) {
            state = .pinnedToBottom
            unseen = 0
            return
        }
        if let pending = pendingRestore, geometry.topAnchor?.rowID != pending.rowID { return }
        pendingRestore = nil
        readingAnchor = geometry.topAnchor ?? readingAnchor
    }

    private mutating func programmaticBottomGeometry(_ geometry: ChatScrollGeometry, sizeChanged: Bool) -> Command {
        if isAtBottom(geometry) {
            state = .pinnedToBottom
            unseen = 0
            repairs = 0
            return .none
        }
        return sizeChanged ? repair() : .none
    }

    private mutating func userScrollBegan() {
        userScrolling = true
        repairs = 0
        pendingRestore = nil
        if case .programmatic = state { state = .readingHistory }
    }

    private mutating func userScrollEnded() {
        userScrolling = false
        if lastIsAtBottom {
            state = .pinnedToBottom
            unseen = 0
            repairs = 0
        } else {
            state = .readingHistory
            readingAnchor = last?.topAnchor ?? readingAnchor
        }
    }

    private mutating func rowsChanged(_ ids: [String]) -> Command {
        defer { knownIDs = ids }
        guard let known = knownIDs else { return .none }
        let knownSet = Set(known)
        let appended = Self.appendedCount(known: known, knownSet: knownSet, ids: ids)
        let prepended = Self.didPrepend(known: known, ids: ids)
        guard state == .readingHistory else { return .none }
        unseen += appended
        guard prepended, let anchor = readingAnchor else { return .none }
        pendingRestore = anchor
        return .restore(anchor)
    }

    private static func appendedCount(known: [String], knownSet: Set<String>, ids: [String]) -> Int {
        guard let tail = known.last, let index = ids.lastIndex(of: tail) else { return 0 }
        return ids[(index + 1)...].filter { !knownSet.contains($0) }.count
    }

    private static func didPrepend(known: [String], ids: [String]) -> Bool {
        guard let head = known.first, let index = ids.firstIndex(of: head) else { return false }
        return index > 0
    }

    private mutating func visibleRowsChanged(_ ids: [String]) {
        visibleIDs = Set(ids)
        if case .programmatic(.row(let id)) = state, visibleIDs.contains(id) { state = .readingHistory }
    }

    private mutating func jump(animated: Bool) -> Command {
        unseen = 0
        repairs = 0
        pendingRestore = nil
        if state == .pinnedToBottom, lastIsAtBottom { return .none }
        state = .programmatic(.bottom)
        return .scrollToBottom(animated: animated)
    }

    private mutating func revealRow(_ id: String) -> Command {
        state = .programmatic(.row(id))
        attempts = 1
        return .scrollToRow(id)
    }

    private mutating func revealRetry() -> Command {
        guard case .programmatic(.row(let id)) = state else { return .none }
        guard !visibleIDs.contains(id), attempts < Self.revealAttempts else {
            state = .readingHistory
            return .none
        }
        attempts += 1
        return .scrollToRow(id)
    }
}
